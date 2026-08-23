#!/usr/bin/env python3
"""Flatten Google Takeout (Google Photos) exports into plain media files with
their metadata baked in.

Takeout gives you nested album folders where each photo/video sits next to a
sidecar JSON (photoTakenTime, GPS, description). This script:

  1. Walks one or more Takeout folders and finds every image/video.
  2. Matches each file to its sidecar JSON (handling Takeout's naming quirks:
     truncated names, "(1)" duplicates, -edited variants).
  3. Copies files into the output folder (flat by default, or one folder per
     album with --by-album), writing EXIF/QuickTime dates, GPS, and description
     into the file itself via exiftool, and setting the file's mtime to the
     photo-taken time.

Usage:
  python3 scripts/flatten_takeout.py ~/Downloads/Takeout -o ~/Pictures/flat
  python3 scripts/flatten_takeout.py Takeout1 Takeout2 -o out --by-album
  python3 scripts/flatten_takeout.py Takeout -o out --dry-run

Requires exiftool (brew install exiftool).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

MEDIA_EXTS = {
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tif", ".tiff",
    ".bmp", ".dng", ".raw", ".cr2", ".nef", ".arw",
    ".mp4", ".mov", ".m4v", ".avi", ".mpg", ".mpeg", ".wmv", ".3gp", ".mkv", ".webm",
}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mpg", ".mpeg", ".wmv", ".3gp", ".mkv", ".webm"}


def find_media(roots):
    for root in roots:
        for path in sorted(Path(root).rglob("*")):
            if path.is_file() and path.suffix.lower() in MEDIA_EXTS:
                yield path


def build_json_index(directory: Path):
    """All sidecar JSONs in a directory, keyed by lowercase filename."""
    return {p.name.lower(): p for p in directory.glob("*.json")}


def sidecar_for(media: Path, index: dict):
    """Find the Takeout sidecar JSON for a media file, tolerating Takeout's
    naming quirks."""
    name = media.name
    stem, ext = media.stem, media.suffix

    # "(1)" duplicates: IMG_001(1).jpg -> sidecar is named IMG_001.jpg(1).json
    dup = re.match(r"^(.*)(\(\d+\))$", stem)
    base_variants = [name]
    if dup:
        base_variants.append(f"{dup.group(1)}{ext}{dup.group(2)}")
    # "-edited" files share the original's sidecar (any language suffix variant).
    edited = re.match(r"^(.*)-(edited|bearbeitet|modifié|editado)$", stem, re.I)
    if edited:
        base_variants.append(f"{edited.group(1)}{ext}")

    candidates = []
    for base in base_variants:
        candidates += [
            f"{base}.supplemental-metadata.json",
            f"{base}.json",
        ]
        # Truncated forms: Takeout cuts the sidecar basename to ~46 chars.
        for cut in range(len(base), 20, -1):
            candidates.append(f"{base[:cut]}.json")
        # Sidecar named without the media extension: IMG_001.json
        candidates.append(f"{Path(base).stem}.json")

    seen = set()
    for cand in candidates:
        key = cand.lower()
        if key in seen:
            continue
        seen.add(key)
        if key in index:
            return index[key]

    # Last resort: any json whose name starts with the media name (truncated
    # supplemental-metadata suffixes land here).
    prefix = name.lower()[:25]
    matches = [p for k, p in index.items() if k.startswith(prefix) and "metadata" in k]
    return matches[0] if len(matches) == 1 else None


def parse_sidecar(path: Path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    meta = {}
    ts = (data.get("photoTakenTime") or {}).get("timestamp") or \
         (data.get("creationTime") or {}).get("timestamp")
    if ts:
        try:
            meta["taken"] = datetime.fromtimestamp(int(ts), tz=timezone.utc)
        except (ValueError, OverflowError):
            pass
    for geo_key in ("geoData", "geoDataExif"):
        geo = data.get(geo_key) or {}
        lat, lon = geo.get("latitude"), geo.get("longitude")
        if lat and lon and not (lat == 0.0 and lon == 0.0):
            meta["lat"], meta["lon"] = lat, lon
            if geo.get("altitude"):
                meta["alt"] = geo["altitude"]
            break
    desc = (data.get("description") or "").strip()
    if desc:
        meta["description"] = desc
    return meta


def unique_dest(directory: Path, name: str, used: set):
    stem, ext = Path(name).stem, Path(name).suffix
    candidate, i = name, 1
    while candidate.lower() in used or (directory / candidate).exists():
        candidate = f"{stem}_{i}{ext}"
        i += 1
    used.add(candidate.lower())
    return directory / candidate


def exiftool_block(dest: Path, meta: dict):
    """One -execute block of exiftool args enriching a single file."""
    args = []
    taken = meta.get("taken")
    if taken:
        stamp = taken.strftime("%Y:%m:%d %H:%M:%S")
        args.append(f"-AllDates={stamp}")
        if dest.suffix.lower() in VIDEO_EXTS:
            args += [f"-QuickTime:CreateDate={stamp}", f"-QuickTime:ModifyDate={stamp}"]
    if "lat" in meta:
        lat, lon = meta["lat"], meta["lon"]
        if dest.suffix.lower() in VIDEO_EXTS:
            args.append(f"-Keys:GPSCoordinates={lat}, {lon}")
        else:
            args += [
                f"-GPSLatitude={abs(lat)}", f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
                f"-GPSLongitude={abs(lon)}", f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}",
            ]
            if "alt" in meta:
                args += [f"-GPSAltitude={abs(meta['alt'])}",
                         f"-GPSAltitudeRef={0 if meta['alt'] >= 0 else 1}"]
    if "description" in meta:
        args += [f"-ImageDescription={meta['description']}",
                 f"-XMP:Description={meta['description']}"]
    if not args:
        return []
    return args + [str(dest), "-execute"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="Takeout folder(s) to scan")
    ap.add_argument("-o", "--output", required=True, help="Destination folder")
    ap.add_argument("--by-album", action="store_true",
                    help="Keep one folder per album instead of fully flat")
    ap.add_argument("--move", action="store_true", help="Move instead of copy")
    ap.add_argument("--dry-run", action="store_true", help="Report without writing")
    args = ap.parse_args()

    if not shutil.which("exiftool"):
        sys.exit("exiftool not found — install with: brew install exiftool")

    out_root = Path(args.output).expanduser()
    json_cache, used_names, plan = {}, {}, []
    stats = {"files": 0, "with_meta": 0, "no_sidecar": 0}

    for media in find_media([Path(p).expanduser() for p in args.inputs]):
        stats["files"] += 1
        directory = media.parent
        if directory not in json_cache:
            json_cache[directory] = build_json_index(directory)
        sidecar = sidecar_for(media, json_cache[directory])
        meta = parse_sidecar(sidecar) if sidecar else {}
        if meta:
            stats["with_meta"] += 1
        elif not sidecar:
            stats["no_sidecar"] += 1

        dest_dir = out_root / media.parent.name if args.by_album else out_root
        used = used_names.setdefault(dest_dir, set())
        dest = unique_dest(dest_dir, media.name, used)
        plan.append((media, dest, meta))

    if args.dry_run:
        for media, dest, meta in plan:
            tags = ",".join(k for k in ("taken", "lat", "description") if k in meta) or "none"
            print(f"{media}  ->  {dest}  [{tags}]")
        print(f"\n{stats['files']} files, {stats['with_meta']} with metadata, "
              f"{stats['no_sidecar']} missing sidecars")
        return

    exif_args = []
    for i, (media, dest, meta) in enumerate(plan, 1):
        dest.parent.mkdir(parents=True, exist_ok=True)
        if args.move:
            shutil.move(str(media), dest)
        else:
            shutil.copy2(media, dest)
        exif_args += exiftool_block(dest, meta)
        if i % 100 == 0:
            print(f"copied {i}/{len(plan)}…")

    if exif_args:
        print("writing metadata with exiftool…")
        argfile = out_root / ".exiftool_args.txt"
        argfile.write_text("\n".join(exif_args), encoding="utf-8")
        result = subprocess.run(
            ["exiftool", "-@", str(argfile), "-common_args", "-overwrite_original",
             "-api", "QuickTimeUTC=1", "-m", "-q"],
            capture_output=True, text=True)
        if result.returncode != 0 and result.stderr:
            print(f"exiftool warnings:\n{result.stderr[:2000]}", file=sys.stderr)
        argfile.unlink(missing_ok=True)

    # File timestamps last, so exiftool rewrites don't clobber them.
    for _, dest, meta in plan:
        if "taken" in meta and dest.exists():
            ts = meta["taken"].timestamp()
            os.utime(dest, (ts, ts))

    print(f"Done: {len(plan)} files -> {out_root}  "
          f"({stats['with_meta']} enriched, {stats['no_sidecar']} had no sidecar JSON)")


if __name__ == "__main__":
    main()

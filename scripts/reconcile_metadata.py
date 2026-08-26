#!/usr/bin/env python3
"""
Reconcile missing photo metadata (dates + GPS) in a Travelog source tree by
finding the *same image* in a large reference library and copying its EXIF.

Why: photos shared through WhatsApp are recompressed and stripped of EXIF.
The originals (e.g. a Google Photos takeout) still hold the metadata. This
script fingerprints images by content (perceptual difference-hash on decoded
pixels — no AI), so a recompressed/resized WhatsApp copy still matches its
original, then uses exiftool to copy DateTimeOriginal/CreateDate + GPS over.

Usage:
  python3 reconcile_metadata.py --source ~/Travelog --library /Volumes/Big/AllPhotos
  python3 reconcile_metadata.py --source ... --library ... --dry-run
  python3 reconcile_metadata.py --source ... --library ... --threshold 8 --workers 10

Design for very large libraries (100k+ images):
  * The library is indexed ONCE into SQLite (path, size, mtime, 64-bit dhash).
    Re-runs only hash new/changed files — unchanged files are skipped.
  * JPEG decoding uses PIL "draft" mode (DCT-domain downscale) so hashing is
    dominated by disk I/O, parallelised across --workers processes.
  * Matching is a linear hamming scan with int.bit_count() over the in-memory
    hash list — ~0.05s per query per million hashes, no extra dependencies.

Requires: exiftool on PATH. Pillow (+ pillow-heif for HEIC) — the script
bootstraps its own venv at ~/.travelog-tools/venv on first run if needed.
"""

import argparse
import csv
import json
import os
import sqlite3
import subprocess
import sys
import time
from multiprocessing import Pool

# ---------------------------------------------------------------- bootstrap

VENV_DIR = os.path.expanduser("~/.travelog-tools/venv")


def ensure_pillow():
    """Re-exec inside a private venv that has Pillow (+ pillow-heif)."""
    try:
        import PIL  # noqa: F401
        return
    except ImportError:
        pass
    venv_python = os.path.join(VENV_DIR, "bin", "python3")
    if os.environ.get("TRAVELOG_BOOTSTRAPPED") == "1":
        sys.exit("error: Pillow still missing inside the bootstrap venv")
    if not os.path.exists(venv_python):
        print("First run: creating a private venv with Pillow (one-time)…")
        import venv as venv_mod
        venv_mod.create(VENV_DIR, with_pip=True)
        subprocess.check_call([venv_python, "-m", "pip", "install", "--quiet",
                               "pillow", "pillow-heif"])
    os.environ["TRAVELOG_BOOTSTRAPPED"] = "1"
    os.execv(venv_python, [venv_python] + sys.argv)


ensure_pillow()

from PIL import Image  # noqa: E402

try:
    import pillow_heif
    pillow_heif.register_heif_opener()
    HEIC_OK = True
except ImportError:
    HEIC_OK = False

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff", ".heic", ".heif"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".webm", ".3gp"}


def to_signed(h):
    """SQLite stores signed 64-bit ints; fold the unsigned hash into range."""
    return h - (1 << 64) if h >= (1 << 63) else h


def to_unsigned(h):
    return h + (1 << 64) if h < 0 else h

# ---------------------------------------------------------------- hashing


def dhash64(path):
    """64-bit difference hash of the decoded image (row-wise gradients)."""
    with Image.open(path) as im:
        # DCT-domain shortcut: decodes JPEGs at ~1/8 size. No-op elsewhere.
        try:
            im.draft("L", (128, 128))
        except Exception:
            pass
        im = im.convert("L").resize((9, 8), Image.BILINEAR)
        px = list(im.getdata())
    bits = 0
    for row in range(8):
        for col in range(8):
            i = row * 9 + col
            bits = (bits << 1) | (1 if px[i] > px[i + 1] else 0)
    return bits


def hash_one(job):
    """Worker: (path, size, mtime) -> (path, size, mtime, hash|None)."""
    path, size, mtime = job
    try:
        return (path, size, mtime, dhash64(path))
    except Exception:
        return (path, size, mtime, None)


# ---------------------------------------------------------------- library index


def open_index(index_path):
    db = sqlite3.connect(index_path)
    db.execute("""CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY, size INTEGER, mtime REAL, hash INTEGER)""")
    return db


def build_index(db, library, workers):
    known = {row[0]: (row[1], row[2])
             for row in db.execute("SELECT path, size, mtime FROM files")}
    jobs, seen, skipped_video = [], set(), 0
    for root, _, names in os.walk(library):
        for name in names:
            ext = os.path.splitext(name)[1].lower()
            path = os.path.join(root, name)
            if ext in VIDEO_EXTS:
                skipped_video += 1
                continue
            if ext not in IMAGE_EXTS:
                continue
            if ext in {".heic", ".heif"} and not HEIC_OK:
                continue
            seen.add(path)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if known.get(path) == (st.st_size, st.st_mtime):
                continue  # already indexed and unchanged
            jobs.append((path, st.st_size, st.st_mtime))

    # Purge index rows for files that vanished from the library.
    gone = set(known) - seen
    if gone:
        db.executemany("DELETE FROM files WHERE path = ?", [(p,) for p in gone])

    if jobs:
        print(f"Indexing {len(jobs):,} new/changed library images "
              f"({len(known):,} already cached, {skipped_video:,} videos ignored)…")
        t0, done = time.time(), 0
        with Pool(workers) as pool:
            for path, size, mtime, h in pool.imap_unordered(hash_one, jobs, chunksize=64):
                if h is not None:
                    db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?)",
                               (path, size, mtime, to_signed(h)))
                done += 1
                if done % 2000 == 0:
                    rate = done / max(time.time() - t0, 0.001)
                    print(f"  {done:,}/{len(jobs):,}  ({rate:,.0f} img/s)")
                    db.commit()
        db.commit()
    else:
        print(f"Library index up to date ({len(known):,} images cached).")

    return [(path, to_unsigned(h)) for path, h in
            db.execute("SELECT path, hash FROM files WHERE hash IS NOT NULL")]


# ---------------------------------------------------------------- source scan


def exiftool_json(paths_or_dir, recursive=False):
    cmd = ["exiftool", "-json", "-fast2", "-n",
           "-DateTimeOriginal", "-CreateDate", "-GPSLatitude", "-GPSLongitude"]
    if recursive:
        cmd.append("-r")
    cmd += paths_or_dir if isinstance(paths_or_dir, list) else [paths_or_dir]
    out = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        return []


def find_candidates(source, need):
    """Source images whose metadata is incomplete."""
    records = exiftool_json(source, recursive=True)
    candidates, videos = [], 0
    for rec in records:
        path = rec.get("SourceFile", "")
        ext = os.path.splitext(path)[1].lower()
        if ext in VIDEO_EXTS:
            videos += 1
            continue
        if ext not in IMAGE_EXTS:
            continue
        has_date = bool(rec.get("DateTimeOriginal") or rec.get("CreateDate"))
        has_gps = rec.get("GPSLatitude") is not None
        missing = ((need == "date" and not has_date)
                   or (need == "gps" and not has_gps)
                   or (need == "either" and (not has_date or not has_gps)))
        if missing:
            candidates.append(path)
    return candidates, videos


# ---------------------------------------------------------------- matching


def best_match(h, index_rows, threshold):
    """Linear hamming scan; returns (path, dist, runner_up_dist)."""
    best_path, best_d, second_d = None, 65, 65
    for path, lib_hash in index_rows:
        d = (h ^ lib_hash).bit_count()
        if d < best_d:
            best_path, second_d, best_d = path, best_d, d
        elif d < second_d:
            second_d = d
    if best_d <= threshold:
        return best_path, best_d, second_d
    return None, best_d, second_d


def copy_metadata(src_of_truth, target, backup):
    cmd = ["exiftool", "-TagsFromFile", src_of_truth,
           "-DateTimeOriginal", "-CreateDate", "-ModifyDate",
           "-gps:all", "-makernotes:all--"]
    if not backup:
        cmd.append("-overwrite_original")
    cmd.append(target)
    out = subprocess.run(cmd, capture_output=True, text=True)
    return out.returncode == 0 and "1 image files updated" in out.stdout


# ---------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True,
                    help="Travelog folder (country subfolders with images)")
    ap.add_argument("--library", required=True,
                    help="big reference folder holding the originals with metadata")
    ap.add_argument("--index", default=None,
                    help="SQLite index cache (default: ~/.travelog-tools/<library>.sqlite)")
    ap.add_argument("--need", choices=["date", "gps", "either"], default="either",
                    help="what counts as 'missing metadata' (default: either)")
    ap.add_argument("--threshold", type=int, default=6,
                    help="max hamming distance 0-64 to accept a match (default 6)")
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--dry-run", action="store_true",
                    help="report matches but modify nothing")
    ap.add_argument("--backup", action="store_true",
                    help="keep exiftool *_original backups of modified files")
    ap.add_argument("--report", default="reconcile-report.csv")
    args = ap.parse_args()

    source = os.path.expanduser(args.source)
    library = os.path.expanduser(args.library)
    for p, label in [(source, "--source"), (library, "--library")]:
        if not os.path.isdir(p):
            sys.exit(f"error: {label} folder not found: {p}")
    if subprocess.run(["which", "exiftool"], capture_output=True).returncode != 0:
        sys.exit("error: exiftool not found — brew install exiftool")

    index_path = args.index or os.path.join(
        os.path.expanduser("~/.travelog-tools"),
        "index-" + str(abs(hash(os.path.abspath(library)))) + ".sqlite")
    os.makedirs(os.path.dirname(index_path), exist_ok=True)

    print(f"Scanning source for images with missing metadata ({args.need})…")
    candidates, src_videos = find_candidates(source, args.need)
    print(f"  {len(candidates)} image(s) need metadata "
          f"({src_videos} videos skipped).")
    if not candidates:
        return

    db = open_index(index_path)
    index_rows = build_index(db, library, args.workers)
    if not index_rows:
        sys.exit("error: the library index is empty — no images found to match against")
    print(f"Matching against {len(index_rows):,} library fingerprints…")

    rows, fixed, unmatched, failed = [], 0, 0, 0
    for i, path in enumerate(candidates, 1):
        try:
            h = dhash64(path)
        except Exception as e:
            rows.append([path, "", "", "", f"undecodable: {e}"])
            failed += 1
            continue
        match, dist, second = best_match(h, index_rows, args.threshold)
        if match is None:
            rows.append([path, "", dist, second, "no match"])
            unmatched += 1
            continue
        if args.dry_run:
            rows.append([path, match, dist, second, "would copy metadata"])
            fixed += 1
        else:
            ok = copy_metadata(match, path, args.backup)
            rows.append([path, match, dist, second,
                         "metadata copied" if ok else "exiftool failed"])
            fixed += ok
            failed += (not ok)
        if i % 25 == 0:
            print(f"  {i}/{len(candidates)} processed…")

    with open(args.report, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["source_image", "matched_original",
                         "hamming_distance", "runner_up_distance", "action"])
        writer.writerows(rows)

    verb = "would fix" if args.dry_run else "fixed"
    print(f"\nDone: {verb} {fixed}, no match {unmatched}, errors {failed}."
          f"\nReport: {os.path.abspath(args.report)}")
    if unmatched:
        print("Tip: raise --threshold (e.g. 10) to match more aggressively; "
              "check runner_up_distance in the report to judge ambiguity.")


if __name__ == "__main__":
    main()

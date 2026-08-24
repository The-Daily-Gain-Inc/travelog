import Foundation
import SwiftData
import ImageIO

/// Albums imported from an external drive (USB-C SSD, SD card) via the Files
/// picker. The chosen folder is kept as a security-scoped bookmark; each
/// subfolder becomes an album exactly like a Drive country folder, and media
/// is copied into the cache on demand while the drive is attached.
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()
    static let idPrefix = "local-"

    private static let bookmarkKey = "externalLibraryBookmark"
    private static let nameKey = "externalLibraryName"

    @Published var isScanning = false
    @Published var lastError: String?

    var libraryName: String? {
        UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
            ? UserDefaults.standard.string(forKey: Self.nameKey) : nil
    }

    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff",
        "mp4", "mov", "m4v", "avi", "webm",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "webm"]

    // MARK: - Connect / remove

    func connect(url: URL, context: ModelContext) async {
        lastError = nil
        guard url.startAccessingSecurityScopedResource() else {
            lastError = String(localized: "Couldn’t access that folder.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.nameKey)
            try scan(root: url, context: context)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rescan(context: ModelContext) async {
        lastError = nil
        guard let root = resolveRoot() else {
            lastError = String(localized: "Drive not connected — plug it in and try again.")
            return
        }
        guard root.startAccessingSecurityScopedResource() else {
            lastError = String(localized: "Couldn’t access the drive.")
            return
        }
        defer { root.stopAccessingSecurityScopedResource() }
        do { try scan(root: root, context: context) } catch { lastError = error.localizedDescription }
    }

    func remove(context: ModelContext) {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        let all = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        for album in all where album.driveId.hasPrefix(Self.idPrefix) {
            context.delete(album)
        }
        try? context.save()
    }

    private func resolveRoot() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    // MARK: - Scanning

    private func scan(root: URL, context: ModelContext) throws {
        isScanning = true
        defer { isScanning = false }
        let fm = FileManager.default
        let subfolders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        let existing = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.driveId, $0) })

        // Drop local albums whose folder disappeared from the drive.
        let liveAlbumIds = Set(subfolders.map { Self.idPrefix + $0.lastPathComponent })
        for album in existing
        where album.driveId.hasPrefix(Self.idPrefix) && !liveAlbumIds.contains(album.driveId) {
            context.delete(album)
            byId[album.driveId] = nil
        }

        for folder in subfolders {
            let albumId = Self.idPrefix + folder.lastPathComponent
            let album = byId[albumId] ?? {
                let a = Album(driveId: albumId, name: folder.lastPathComponent)
                context.insert(a)
                return a
            }()
            album.name = folder.lastPathComponent
            album.lastSynced = .now

            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]))?
                .filter { Self.mediaExtensions.contains($0.pathExtension.lowercased()) } ?? []
            let liveItemIds = Set(files.map { itemId(album: folder.lastPathComponent, file: $0.lastPathComponent) })
            var itemById = Dictionary(uniqueKeysWithValues: album.items.map { ($0.driveId, $0) })
            for item in album.items where !liveItemIds.contains(item.driveId) {
                context.delete(item)
                itemById[item.driveId] = nil
            }

            for file in files {
                let id = itemId(album: folder.lastPathComponent, file: file.lastPathComponent)
                guard itemById[id] == nil else { continue }
                let values = try? file.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                let isVideo = Self.videoExtensions.contains(file.pathExtension.lowercased())
                let meta = isVideo ? nil : imageMetadata(of: file)
                let item = MediaItem(
                    driveId: id,
                    name: file.lastPathComponent,
                    mimeType: isVideo ? "video/\(file.pathExtension.lowercased())" : "image/\(file.pathExtension.lowercased())",
                    createdTime: meta?.date ?? values?.creationDate ?? .now,
                    sizeBytes: Int64(values?.fileSize ?? 0)
                )
                item.latitude = meta?.latitude
                item.longitude = meta?.longitude
                item.album = album
                context.insert(item)
            }
        }
        try context.save()
    }

    private func itemId(album: String, file: String) -> String {
        "\(Self.idPrefix)\(album)/\(file)"
    }

    private func imageMetadata(of url: URL) -> (latitude: Double?, longitude: Double?, date: Date?)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var lat: Double?
        var lon: Double?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let rawLat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let rawLon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            lat = latRef == "S" ? -rawLat : rawLat
            lon = lonRef == "W" ? -rawLon : rawLon
        }
        var date: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = .current
            date = f.date(from: raw)
        }
        return (lat, lon, date)
    }

    // MARK: - File access for MediaCache

    /// Copies an external item to `destination`. Fails if the drive is detached
    /// and the file was never cached.
    func copyFile(driveId: String, to destination: URL) -> Bool {
        guard driveId.hasPrefix(Self.idPrefix), let root = resolveRoot() else { return false }
        let relative = String(driveId.dropFirst(Self.idPrefix.count))
        guard root.startAccessingSecurityScopedResource() else { return false }
        defer { root.stopAccessingSecurityScopedResource() }
        let source = root.appendingPathComponent(relative)
        return (try? FileManager.default.copyItem(at: source, to: destination)) != nil
    }
}

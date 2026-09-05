import Foundation
import UIKit
import AVFoundation

/// Downloads Drive media to the caches directory and hands back local URLs.
/// Full files are cached by drive id; thumbnails are downscaled and cached separately.
actor MediaCache {
    static let shared = MediaCache()

    private let drive = DriveService()
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// Decoded thumbnails, so a grid cell scrolling back into view doesn't
    /// re-read and re-decode its JPEG. ~50 MB of 600px thumbnails.
    private let thumbnails: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 50 * 1024 * 1024
        return c
    }()

    /// A UIImage decodes lazily, on the main thread, the first time it is
    /// drawn — which is exactly where a scrolling grid stutters. Decode here,
    /// on the actor, and hand SwiftUI a bitmap that is ready to blit.
    private static func predecoded(_ img: UIImage) -> UIImage {
        img.preparingForDisplay() ?? img
    }

    private static func cost(_ img: UIImage) -> Int {
        Int(img.size.width * img.scale * img.size.height * img.scale * 4)
    }

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func localURL(for id: String, ext: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension(ext)
    }

    /// Fast check: is this item already on disk?
    func isCached(_ item: (driveId: String, name: String)) -> Bool {
        let ext = (item.name as NSString).pathExtension.lowercased()
        return FileManager.default.fileExists(
            atPath: localURL(for: item.driveId, ext: ext.isEmpty ? "bin" : ext).path
        )
    }

    /// Returns a local file URL for the full media item, downloading it if needed.
    func file(for item: (driveId: String, name: String)) async throws -> URL {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let dest = localURL(for: item.driveId, ext: ext.isEmpty ? "bin" : ext)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        // Respect the Wi-Fi-only preference for fresh Drive downloads.
        if UserDefaults.standard.bool(forKey: "wifiOnlyDownloads"),
           NetworkMonitor.shared.isExpensive,
           !item.driveId.hasPrefix(MockData.idPrefix),
           !item.driveId.hasPrefix(LocalLibrary.idPrefix) {
            throw URLError(.notConnectedToInternet)
        }

        if item.driveId.hasPrefix(MockData.idPrefix) {
            let img = await MainActor.run { MockData.renderImage(for: item.driveId) }
            try img.jpegData(compressionQuality: 0.85)?.write(to: dest)
            return dest
        }

        if item.driveId.hasPrefix(LocalLibrary.idPrefix) {
            let copied = await MainActor.run { LocalLibrary.shared.copyFile(driveId: item.driveId, to: dest) }
            guard copied else { throw URLError(.fileDoesNotExist) }
            return dest
        }

        if let existing = inFlight[item.driveId] { return try await existing.value }
        let task = Task<URL, Error> {
            let token = try await AuthService.shared.accessToken()
            var req = URLRequest(url: drive.downloadURL(for: item.driveId))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        }
        inFlight[item.driveId] = task
        defer { inFlight[item.driveId] = nil }
        return try await task.value
    }

    /// Downscaled thumbnail for grids. Photos are decoded via ImageIO; videos
    /// get a poster frame extracted from the start of the clip.
    func thumbnail(for item: (driveId: String, name: String), maxPixel: CGFloat = 600) async throws -> UIImage {
        let cacheKey = item.driveId as NSString
        if let img = thumbnails.object(forKey: cacheKey) { return img }
        let thumbURL = localURL(for: item.driveId + "_thumb", ext: "jpg")
        if let data = try? Data(contentsOf: thumbURL), let img = UIImage(data: data) {
            let ready = Self.predecoded(img)
            thumbnails.setObject(ready, forKey: cacheKey, cost: Self.cost(ready))
            return ready
        }

        let full = try await file(for: item)
        let img: UIImage
        if ["mp4", "mov", "m4v", "avi", "webm"].contains(full.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: full))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let cg = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            img = UIImage(cgImage: cg)
        } else {
            img = try Self.downsample(url: full, maxPixel: maxPixel)
        }
        try? img.jpegData(compressionQuality: 0.8)?.write(to: thumbURL)
        let ready = Self.predecoded(img)
        thumbnails.setObject(ready, forKey: cacheKey, cost: Self.cost(ready))
        return ready
    }

    /// Full-quality-ish image for the slideshow, honoring the user's display
    /// resolution setting (0 = original file, decoded as-is).
    func displayImage(for item: (driveId: String, name: String), maxPixel: CGFloat) async throws -> UIImage {
        let full = try await file(for: item)
        guard maxPixel > 0 else {
            guard let img = UIImage(contentsOfFile: full.path) else {
                throw URLError(.cannotDecodeContentData)
            }
            return Self.predecoded(img)
        }
        let cacheURL = localURL(for: item.driveId + "_disp\(Int(maxPixel))", ext: "jpg")
        if let data = try? Data(contentsOf: cacheURL), let img = UIImage(data: data) { return Self.predecoded(img) }
        let img = try Self.downsample(url: full, maxPixel: maxPixel)
        try? img.jpegData(compressionQuality: 0.9)?.write(to: cacheURL)
        return Self.predecoded(img)
    }

    private static func downsample(url: URL, maxPixel: CGFloat) throws -> UIImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cg)
    }

    func clear() {
        thumbnails.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Deletes the oldest cached files until the cache fits under `maxBytes`.
    func enforceLimit(maxBytes: Int64) {
        guard maxBytes > 0 else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (url: URL, size: Int64, date: Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }
        files.sort { $0.date < $1.date }
        for file in files {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    func sizeOnDisk() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

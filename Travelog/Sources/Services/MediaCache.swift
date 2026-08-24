import Foundation
import UIKit
import AVFoundation

/// Downloads Drive media to the caches directory and hands back local URLs.
/// Full files are cached by drive id; thumbnails are downscaled and cached separately.
actor MediaCache {
    static let shared = MediaCache()

    private let drive = DriveService()
    private var inFlight: [String: Task<URL, Error>] = [:]

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func localURL(for id: String, ext: String) -> URL {
        dir.appendingPathComponent(id).appendingPathExtension(ext)
    }

    /// Returns a local file URL for the full media item, downloading it if needed.
    func file(for item: (driveId: String, name: String)) async throws -> URL {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let dest = localURL(for: item.driveId, ext: ext.isEmpty ? "bin" : ext)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        if item.driveId.hasPrefix(MockData.idPrefix) {
            let img = await MainActor.run { MockData.renderImage(for: item.driveId) }
            try img.jpegData(compressionQuality: 0.85)?.write(to: dest)
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
        let thumbURL = localURL(for: item.driveId + "_thumb", ext: "jpg")
        if let data = try? Data(contentsOf: thumbURL), let img = UIImage(data: data) { return img }

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
        return img
    }

    /// Full-quality-ish image for the slideshow, honoring the user's display
    /// resolution setting (0 = original file, decoded as-is).
    func displayImage(for item: (driveId: String, name: String), maxPixel: CGFloat) async throws -> UIImage {
        let full = try await file(for: item)
        guard maxPixel > 0 else {
            guard let img = UIImage(contentsOfFile: full.path) else {
                throw URLError(.cannotDecodeContentData)
            }
            return img
        }
        let cacheURL = localURL(for: item.driveId + "_disp\(Int(maxPixel))", ext: "jpg")
        if let data = try? Data(contentsOf: cacheURL), let img = UIImage(data: data) { return img }
        let img = try Self.downsample(url: full, maxPixel: maxPixel)
        try? img.jpegData(compressionQuality: 0.9)?.write(to: cacheURL)
        return img
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
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func sizeOnDisk() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

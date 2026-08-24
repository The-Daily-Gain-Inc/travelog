import Foundation
import SwiftUI

/// Pre-downloads whole albums into the media cache so slideshows work offline.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Album driveId → fraction complete (removed when finished).
    @Published var progress: [String: Double] = [:]

    func isDownloading(_ album: Album) -> Bool {
        progress[album.driveId] != nil
    }

    func download(_ album: Album) {
        guard !isDownloading(album) else { return }
        let albumId = album.driveId
        let items = album.items.map { (driveId: $0.driveId, name: $0.name) }
        progress[albumId] = 0
        Task {
            for (i, item) in items.enumerated() {
                _ = try? await MediaCache.shared.file(for: item)
                progress[albumId] = Double(i + 1) / Double(max(items.count, 1))
            }
            progress[albumId] = nil
        }
    }
}

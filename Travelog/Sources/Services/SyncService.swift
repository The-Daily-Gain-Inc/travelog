import Foundation
import SwiftData

/// Mirrors the Drive folder structure into SwiftData:
/// <root folder> / <Country> / photos & videos
@MainActor
final class SyncService: ObservableObject {
    @Published var isSyncing = false
    @Published var progressText: String?
    @Published var lastError: String?

    private let drive = DriveService()

    func sync(rootFolderName: String, context: ModelContext) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false; progressText = nil }
        do {
            let token = try await AuthService.shared.accessToken()
            guard let root = try await drive.findRootFolder(named: rootFolderName, token: token) else {
                lastError = String(localized: "Folder “\(rootFolderName)” not found in Drive.")
                return
            }
            let folders = try await drive.subfolders(of: root.id, token: token)
            let existing = try context.fetch(FetchDescriptor<Album>())
            var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.driveId, $0) })

            // Remove albums that no longer exist in Drive (mock albums untouched).
            let liveIds = Set(folders.map(\.id))
            for album in existing where !liveIds.contains(album.driveId) && !album.driveId.hasPrefix(MockData.idPrefix) {
                context.delete(album)
                byId[album.driveId] = nil
            }

            for (i, folder) in folders.enumerated() {
                progressText = String(localized: "Syncing \(folder.name) (\(i + 1)/\(folders.count))…")
                let album = byId[folder.id] ?? {
                    let a = Album(driveId: folder.id, name: folder.name)
                    context.insert(a)
                    return a
                }()
                album.name = folder.name
                album.lastSynced = .now

                let files = try await drive.mediaFiles(in: folder.id, token: token)
                let liveFileIds = Set(files.map(\.id))
                var itemById = Dictionary(uniqueKeysWithValues: album.items.map { ($0.driveId, $0) })
                for item in album.items where !liveFileIds.contains(item.driveId) {
                    context.delete(item)
                    itemById[item.driveId] = nil
                }
                for file in files {
                    if let item = itemById[file.id] {
                        item.name = file.name
                        item.mimeType = file.mimeType
                    } else {
                        let item = MediaItem(
                            driveId: file.id,
                            name: file.name,
                            mimeType: file.mimeType,
                            createdTime: file.createdTime ?? .now,
                            sizeBytes: Int64(file.size ?? "0") ?? 0
                        )
                        item.album = album
                        context.insert(item)
                    }
                }
            }
            try context.save()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

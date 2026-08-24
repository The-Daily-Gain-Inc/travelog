import Foundation
import SwiftData

/// An album maps 1:1 to a Google Drive folder. Folder name == country name.
@Model
final class Album {
    @Attribute(.unique) var driveId: String
    var name: String
    var lastSynced: Date
    /// User-chosen cover photo (driveId of one of the items).
    var coverDriveId: String?
    var isPinned: Bool = false
    /// Free-form note shown in the album header.
    var note: String = ""
    @Relationship(deleteRule: .cascade, inverse: \MediaItem.album)
    var items: [MediaItem] = []

    init(driveId: String, name: String, lastSynced: Date = .now) {
        self.driveId = driveId
        self.name = name
        self.lastSynced = lastSynced
    }
}

@Model
final class MediaItem {
    @Attribute(.unique) var driveId: String
    var name: String
    var mimeType: String
    var createdTime: Date
    var sizeBytes: Int64
    // EXIF GPS position from Drive's image metadata, when the photo has one.
    var latitude: Double?
    var longitude: Double?
    var isFavorite: Bool = false
    var isHidden: Bool = false
    var album: Album?

    var isVideo: Bool { mimeType.hasPrefix("video/") }

    init(driveId: String, name: String, mimeType: String, createdTime: Date, sizeBytes: Int64) {
        self.driveId = driveId
        self.name = name
        self.mimeType = mimeType
        self.createdTime = createdTime
        self.sizeBytes = sizeBytes
    }
}

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the widget shows. Compiled into the app and the extension.
struct WidgetSnapshot: Codable, Equatable {
    var countries: Int
    var photos: Int
    var trips: Int
    /// "Portugal · Jun 2025"
    var lastTrip: String?
    /// A memory from this week in a past year: caption + image file in the
    /// shared container (nil when there is none).
    var memoryCaption: String?
    var memoryYear: Int?
    var memoryImageFile: String?
    var updatedAt: Date

    static let placeholder = WidgetSnapshot(countries: 23, photos: 4_812, trips: 31,
                                            lastTrip: "Portugal · Jun 2025",
                                            memoryCaption: "Lisbon", memoryYear: 2023,
                                            memoryImageFile: nil, updatedAt: Date())
    static let empty = WidgetSnapshot(countries: 0, photos: 0, trips: 0, lastTrip: nil,
                                      memoryCaption: nil, memoryYear: nil, memoryImageFile: nil,
                                      updatedAt: .distantPast)
}

enum WidgetBridge {
    static let appGroup = "group.ca.thedailygain.Travelog"
    static let snapshotKey = "widget_snapshot_v1"
    static let widgetKind = "TravelogMemoryWidget"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: snapshotKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }
}

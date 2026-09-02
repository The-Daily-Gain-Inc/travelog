import SwiftData
import UIKit

/// Builds the widget snapshot from the library: passport stats and one
/// "on this day" memory (a small JPEG copied into the App Group container).
@MainActor
enum WidgetPublisher {
    static func publish(context: ModelContext) async {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let all = albums.flatMap(\.items).filter { !$0.isHidden }
        guard !all.isEmpty else { WidgetBridge.save(.empty); return }

        let calendar = Calendar.current
        let countries = Set(albums.compactMap { WorldGeometry.feature(for: $0)?.id }).count
        let photos = all.filter { !$0.isVideo }.count

        // Trips: >14-day gaps, same rule as the Trips tab.
        let sorted = all.sorted { $0.createdTime < $1.createdTime }
        var trips = 0
        var last: Date?
        for item in sorted {
            if last == nil || item.createdTime.timeIntervalSince(last!) > 14 * 86_400 { trips += 1 }
            last = item.createdTime
        }
        var lastTrip: String?
        if let latest = sorted.last {
            let name = latest.album?.name ?? ""
            lastTrip = "\(name) · \(latest.createdTime.formatted(.dateTime.month(.abbreviated).year()))"
        }

        // On this day (±3 days, an earlier year); prefer a favorite photo.
        let today = calendar.ordinality(of: .day, in: .year, for: .now) ?? 0
        let thisYear = calendar.component(.year, from: .now)
        let candidates = all.filter { item in
            guard !item.isVideo, calendar.component(.year, from: item.createdTime) < thisYear,
                  let day = calendar.ordinality(of: .day, in: .year, for: item.createdTime) else { return false }
            return abs(day - today) <= 3
        }
        // Deterministic pick per day so the widget doesn't flicker between refreshes.
        let pick = (candidates.filter(\.isFavorite).isEmpty ? candidates : candidates.filter(\.isFavorite))
            .sorted { $0.driveId < $1.driveId }
        var caption: String?, year: Int?, file: String?
        if !pick.isEmpty {
            let item = pick[today % pick.count]
            caption = item.album?.name
            year = calendar.component(.year, from: item.createdTime)
            if let dir = WidgetBridge.containerURL,
               let img = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 800),
               let data = img.jpegData(compressionQuality: 0.75) {
                let url = dir.appendingPathComponent("memory.jpg")
                try? data.write(to: url, options: .atomic)
                file = "memory.jpg"
            }
        }

        WidgetBridge.save(WidgetSnapshot(countries: countries, photos: photos, trips: trips,
                                         lastTrip: lastTrip, memoryCaption: caption, memoryYear: year,
                                         memoryImageFile: file, updatedAt: Date()))
    }
}

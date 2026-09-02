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

        // On this day (±3 days, an earlier year) when there is one, else the
        // whole library; favorites first. A dozen get written out so the
        // widget can shuffle through them during the day.
        let today = calendar.ordinality(of: .day, in: .year, for: .now) ?? 0
        let thisYear = calendar.component(.year, from: .now)
        let candidates = all.filter { item in
            guard !item.isVideo, calendar.component(.year, from: item.createdTime) < thisYear,
                  let day = calendar.ordinality(of: .day, in: .year, for: item.createdTime) else { return false }
            return abs(day - today) <= 3
        }
        let onThisDay = !candidates.isEmpty
        let pool = onThisDay ? candidates : all.filter { !$0.isVideo }
        var picks = pool.filter(\.isFavorite)
        if picks.count < 12 { picks += pool.filter { !$0.isFavorite } }
        // Deterministic shuffle per day: same set all day, new set tomorrow.
        var rng = SeededGenerator(seed: UInt64(today &+ thisYear &* 1000))
        picks = Array(picks.shuffled(using: &rng).prefix(12))

        var memories: [WidgetMemory] = []
        if let dir = WidgetBridge.containerURL {
            for (i, item) in picks.enumerated() {
                guard let img = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 800),
                      let data = img.jpegData(compressionQuality: 0.75) else { continue }
                let name = "memory_\(i).jpg"
                try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
                memories.append(WidgetMemory(caption: item.album?.name ?? "",
                                             year: calendar.component(.year, from: item.createdTime),
                                             file: name, isOnThisDay: onThisDay))
            }
        }
        let first = memories.first

        WidgetBridge.save(WidgetSnapshot(countries: countries, photos: photos, trips: trips,
                                         lastTrip: lastTrip,
                                         memoryCaption: first?.caption, memoryYear: first?.year,
                                         memoryImageFile: first?.file, isOnThisDay: first?.isOnThisDay ?? false,
                                         memories: memories, updatedAt: Date()))
    }
}

/// Tiny deterministic PRNG (SplitMix64) so the day's shuffle is stable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

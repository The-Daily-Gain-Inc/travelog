import WidgetKit
import SwiftUI

struct MemoryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let image: UIImage?
    let isEmpty: Bool
}

struct MemoryProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoryEntry { MemoryEntry(date: Date(), snapshot: .placeholder, image: nil, isEmpty: false) }
    func getSnapshot(in context: Context, completion: @escaping (MemoryEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoryEntry>) -> Void) {
        let midnight = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        completion(Timeline(entries: [current()], policy: .after(midnight)))
    }
    private func current() -> MemoryEntry {
        guard let s = WidgetBridge.load(), s.updatedAt > .distantPast else {
            return MemoryEntry(date: Date(), snapshot: .empty, image: nil, isEmpty: true)
        }
        var image: UIImage?
        if let f = s.memoryImageFile, let dir = WidgetBridge.containerURL,
           let data = try? Data(contentsOf: dir.appendingPathComponent(f)) {
            image = UIImage(data: data)
        }
        return MemoryEntry(date: Date(), snapshot: s, image: image, isEmpty: false)
    }
}

struct MemoryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MemoryEntry
    private var s: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "globe.americas.fill").font(.caption2)
                    Text("\(s.countries)").font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("\(s.countries) countries", systemImage: "globe.americas.fill").font(.caption.weight(.semibold))
                Text("\(s.photos) photos · \(s.trips) trips").font(.caption2)
                if let c = s.memoryCaption, let y = s.memoryYear { Text("\(s.isOnThisDay ? "On this day" : "Memory"): \(c) \(String(y))").font(.caption2) }
            }
        case .accessoryInline:
            Text(s.memoryCaption.map { "On this day: \($0) \(s.memoryYear.map(String.init) ?? "")" } ?? "\(s.countries) countries visited")
        default:
            photoCard
        }
    }

    /// Home screen: the memory photo full-bleed with caption; stats strip on
    /// medium/large. Without a memory this week, a passport stats card.
    private var photoCard: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = entry.image {
                Image(uiImage: img).resizable().scaledToFill()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(red: 0.10, green: 0.35, blue: 0.55), Color(red: 0.05, green: 0.18, blue: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 72)).foregroundStyle(.white.opacity(0.12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(-10)
            }
            VStack(alignment: .leading, spacing: 3) {
                if entry.isEmpty {
                    Text("Open Travelog to sync your library").font(.caption.weight(.semibold))
                } else if let c = s.memoryCaption, let y = s.memoryYear {
                    Text(s.isOnThisDay ? "On this day · \(String(y))" : "Memory · \(String(y))")
                        .font(.caption2.weight(.semibold)).opacity(0.85)
                    Text(c).font(.system(.title3, design: .rounded).weight(.bold)).lineLimit(1)
                } else {
                    Text("Passport").font(.caption2.weight(.semibold)).opacity(0.85)
                    Text("\(s.countries) countries").font(.system(.title3, design: .rounded).weight(.bold))
                }
                if family != .systemSmall, !entry.isEmpty {
                    HStack(spacing: 10) {
                        stat("\(s.countries)", "countries")
                        stat("\(s.trips)", "trips")
                        stat("\(s.photos)", "photos")
                        if let l = s.lastTrip { Text(l).font(.caption2).opacity(0.85).lineLimit(1) }
                    }
                    .padding(.top, 2)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        HStack(spacing: 3) {
            Text(v).font(.caption.weight(.bold))
            Text(l).font(.caption2).opacity(0.85)
        }
    }
}

struct TravelogMemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.widgetKind, provider: MemoryProvider()) { entry in
            MemoryWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Memories")
        .description("A photo from this week in a past year, plus your passport stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

@main
struct TravelogWidgetBundle: WidgetBundle {
    var body: some Widget { TravelogMemoryWidget() }
}

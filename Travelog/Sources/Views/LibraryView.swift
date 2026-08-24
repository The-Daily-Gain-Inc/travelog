import SwiftUI
import SwiftData

/// Photos tab: the whole library as a tight, date-sectioned thumbnail grid
/// with a highlights carousel on top — Google Photos style.
struct LibraryView: View {
    @Query private var albums: [Album]
    @AppStorage("showHiddenItems") private var showHiddenItems = false
    @State private var startItem: MediaItem?
    @State private var highlight: Highlight?
    @State private var searchText = ""
    @State private var mediaFilter = "all"

    struct Highlight: Identifiable {
        let id: String
        let title: String
        let items: [MediaItem]
    }

    private var allItems: [MediaItem] {
        albums.flatMap(\.items)
            .filter { showHiddenItems || !$0.isHidden }
            .filter { item in
                switch mediaFilter {
                case "favorites": item.isFavorite
                case "videos": item.isVideo
                default: true
                }
            }
            .filter { item in
                searchText.isEmpty
                    || WorldGeometry.normalize(item.name).contains(WorldGeometry.normalize(searchText))
                    || WorldGeometry.normalize(item.album?.name ?? "").contains(WorldGeometry.normalize(searchText))
            }
            .sorted { $0.createdTime > $1.createdTime }
    }

    /// Month-grouped sections, newest first.
    private var sections: [(title: String, items: [MediaItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allItems) { item in
            calendar.date(from: calendar.dateComponents([.year, .month], from: item.createdTime)) ?? .distantPast
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (title: $0.key.formatted(.dateTime.month(.wide).year()), items: $0.value) }
    }

    /// Memories carousel: favorites, On This Day, and one card per busy album-year.
    private var highlights: [Highlight] {
        var result: [Highlight] = []
        let favorites = allItems.filter(\.isFavorite)
        if !favorites.isEmpty {
            result.append(Highlight(id: "favs", title: String(localized: "Favorites"), items: favorites))
        }
        let calendar = Calendar.current
        let today = calendar.ordinality(of: .day, in: .year, for: .now) ?? 0
        let thisYear = calendar.component(.year, from: .now)
        let onThisDay = allItems.filter { item in
            guard calendar.component(.year, from: item.createdTime) < thisYear,
                  let day = calendar.ordinality(of: .day, in: .year, for: item.createdTime) else { return false }
            return abs(day - today) <= 3
        }
        if !onThisDay.isEmpty {
            result.append(Highlight(id: "otd", title: String(localized: "On This Day"), items: onThisDay))
        }
        // Album-year memories, biggest first.
        var memories: [(key: String, title: String, items: [MediaItem])] = []
        for album in albums {
            let byYear = Dictionary(grouping: album.items.filter { !$0.isHidden }) {
                calendar.component(.year, from: $0.createdTime)
            }
            for (year, items) in byYear where items.count >= 3 {
                memories.append((key: "\(album.driveId)-\(year)", title: "\(album.name) \(String(year))", items: items))
            }
        }
        for memory in memories.sorted(by: { $0.items.count > $1.items.count }).prefix(6) {
            result.append(Highlight(id: memory.key, title: memory.title, items: memory.items))
        }
        return result
    }

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 160), spacing: 2)]

    private var availableYears: [Int] {
        let calendar = Calendar.current
        return Set(allItems.map { calendar.component(.year, from: $0.createdTime) }).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                if allItems.isEmpty {
                    ContentUnavailableView(
                        "No Photos Yet",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Sync your Google Drive from Settings to load your library.")
                    )
                    .padding(.top, 120)
                } else {
                    if !highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Highlights")
                                .font(.title3.bold())
                                .padding(.horizontal, 16)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(highlights) { item in
                                        Button { highlight = item } label: {
                                            HighlightCard(highlight: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.top, 8)
                    }

                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.title) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(section.items) { item in
                                        TappableThumbnail(item: item) { startItem = item }
                                            .aspectRatio(1, contentMode: .fill)
                                    }
                                }
                            } header: {
                                Text(section.title)
                                    .font(.headline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(.leading, 8)
                                    .padding(.top, 10)
                                    .id(section.title)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .navigationTitle("Photos")
            .searchable(text: $searchText, prompt: Text("Search photos and countries"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Filter", selection: $mediaFilter) {
                        Text("All").tag("all")
                        Label("Favorites", systemImage: "heart").tag("favorites")
                        Label("Videos", systemImage: "video").tag("videos")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(availableYears, id: \.self) { year in
                            Button(String(year)) {
                                if let target = sections.first(where: {
                                    Calendar.current.component(.year, from: $0.items.first?.createdTime ?? .now) == year
                                })?.title {
                                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                                }
                            }
                        }
                    } label: {
                        Label("Jump to year", systemImage: "calendar")
                    }
                }
            }
            .fullScreenCover(item: $startItem) { item in
                SlideshowView(title: String(localized: "Photos"), items: allItems, startItem: item)
            }
            .fullScreenCover(item: $highlight) { highlight in
                SlideshowView(title: highlight.title, items: highlight.items, forceShuffle: highlight.id == "favs")
            }
            }
        }
    }
}

struct HighlightCard: View {
    let highlight: LibraryView.Highlight
    @State private var cover: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                Text("\(highlight.items.count) photos")
                    .font(.caption2)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .frame(width: 168, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task {
            guard cover == nil,
                  let item = highlight.items.first(where: { !$0.isVideo }) ?? highlight.items.first else { return }
            cover = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 400)
        }
    }
}

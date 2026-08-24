import SwiftUI
import SwiftData
import Charts

/// Stats tab: travel numbers derived from the synced library.
struct YearRecap: Identifiable {
    let year: Int
    let items: [MediaItem]
    var id: Int { year }
}

struct StatsView: View {
    @Query private var albums: [Album]
    @State private var showPassport = false
    @State private var showQuiz = false
    @AppStorage("wishlistIds") private var wishlistIdsRaw = ""

    private var wishlistCountries: [CountryFeature] {
        let ids = Set(wishlistIdsRaw.split(separator: ",").map(String.init))
        return WorldGeometry.countries.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
    }
    @State private var recap: YearRecap?

    private var allItems: [MediaItem] { albums.flatMap(\.items) }
    private var photoCount: Int { allItems.filter { !$0.isVideo }.count }
    private var videoCount: Int { allItems.filter(\.isVideo).count }
    private var locatedCount: Int { allItems.filter { $0.latitude != nil }.count }

    private var countriesVisited: Int {
        Set(albums.compactMap { WorldGeometry.feature(for: $0)?.id }).count
    }

    private var topAlbum: Album? {
        albums.max { $0.items.count < $1.items.count }
    }

    /// Items grouped into trips by >14-day gaps (mirrors the Trips tab).
    private var tripGroups: [Trip] {
        let sorted = allItems.filter { !$0.isHidden }.sorted { $0.createdTime < $1.createdTime }
        guard !sorted.isEmpty else { return [] }
        var groups: [[MediaItem]] = [[]]
        var last: Date?
        for item in sorted {
            if let last, item.createdTime.timeIntervalSince(last) > 14 * 86_400 { groups.append([]) }
            groups[groups.count - 1].append(item)
            last = item.createdTime
        }
        return groups.filter { !$0.isEmpty }.enumerated().map { Trip(id: "s\($0.offset)", items: $0.element) }
    }

    private var totalDistanceKm: Double {
        tripGroups.reduce(0) { $0 + $1.distanceKm }
    }

    private var longestTripDays: Int {
        tripGroups.map {
            (Calendar.current.dateComponents([.day], from: $0.start, to: $0.end).day ?? 0) + 1
        }.max() ?? 0
    }

    private var farthestTripKm: Double {
        tripGroups.map(\.distanceKm).max() ?? 0
    }

    private var busiestMonth: (name: String, count: Int)? {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allItems) { item in
            calendar.date(from: calendar.dateComponents([.year, .month], from: item.createdTime)) ?? .distantPast
        }
        guard let best = grouped.max(by: { $0.value.count < $1.value.count }) else { return nil }
        return (best.key.formatted(.dateTime.month(.wide).year()), best.value.count)
    }

    private var firstTrip: Date? { allItems.map(\.createdTime).min() }
    private var latestTrip: Date? { allItems.map(\.createdTime).max() }

    private var photosPerYear: [(year: Int, count: Int)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allItems) { calendar.component(.year, from: $0.createdTime) }
        return grouped.map { ($0.key, $0.value.count) }.sorted { $0.year < $1.year }
    }

    private let worldCountryCount = 195

    private var visitedFeatures: [CountryFeature] {
        var seen = Set<String>()
        return albums.compactMap { WorldGeometry.feature(for: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    /// (continent, visited, total-in-dataset) sorted by visited desc.
    private var continentBreakdown: [(name: String, visited: Int, total: Int)] {
        var totals: [String: Int] = [:]
        for country in WorldGeometry.countries {
            if let c = WorldGeometry.continent(of: country), c != "Antarctica" {
                totals[c, default: 0] += 1
            }
        }
        var visited: [String: Int] = [:]
        for feature in visitedFeatures {
            if let c = WorldGeometry.continent(of: feature) { visited[c, default: 0] += 1 }
        }
        return totals.map { (name: $0.key, visited: visited[$0.key] ?? 0, total: $0.value) }
            .sorted { ($0.visited, $0.name) > ($1.visited, $1.name) }
    }

    /// Unvisited countries nearest to somewhere already visited.
    private var suggestions: [CountryFeature] {
        let visitedIds = Set(visitedFeatures.map(\.id))
        let visitedCenters = visitedFeatures.compactMap { WorldGeometry.centroid(of: $0) }
        guard !visitedCenters.isEmpty else { return [] }
        func nearest(_ feature: CountryFeature) -> Double {
            guard let c = WorldGeometry.centroid(of: feature) else { return .infinity }
            return visitedCenters.map {
                let dLat = $0.latitude - c.latitude
                let dLon = ($0.longitude - c.longitude) * cos(c.latitude * .pi / 180)
                return dLat * dLat + dLon * dLon
            }.min() ?? .infinity
        }
        return WorldGeometry.countries
            .filter { !visitedIds.contains($0.id) && WorldGeometry.continent(of: $0) != "Antarctica" }
            .sorted { nearest($0) < nearest($1) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("World coverage") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(countriesVisited)")
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                            Text("of \(worldCountryCount) countries")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Double(countriesVisited) / Double(worldCountryCount),
                                 format: .percent.precision(.fractionLength(1)))
                                .font(.title3.bold())
                                .foregroundStyle(Color.appAccent)
                        }
                        ProgressView(value: Double(countriesVisited), total: Double(worldCountryCount))
                            .tint(Color.appAccent)
                    }
                    .padding(.vertical, 6)
                }

                Section("Library") {
                    LabeledContent("Photos", value: "\(photoCount)")
                    LabeledContent("Videos", value: "\(videoCount)")
                    LabeledContent("With location", value: "\(locatedCount)")
                    if let topAlbum {
                        LabeledContent("Most photographed", value: "\(topAlbum.name) (\(topAlbum.items.count))")
                    }
                    if totalDistanceKm >= 1 {
                        LabeledContent("Distance traveled", value: "\(Int(totalDistanceKm.rounded()).formatted()) km")
                    }
                    if let firstTrip, let latestTrip {
                        LabeledContent("First memory", value: firstTrip.formatted(.dateTime.month(.wide).year()))
                        LabeledContent("Latest memory", value: latestTrip.formatted(.dateTime.month(.wide).year()))
                    }
                }

                if !tripGroups.isEmpty {
                    Section("Records") {
                        if longestTripDays > 0 {
                            LabeledContent("Longest trip", value: "\(longestTripDays) days")
                        }
                        if farthestTripKm >= 1 {
                            LabeledContent("Farthest trip", value: "\(Int(farthestTripKm.rounded()).formatted()) km")
                        }
                        if let busiestMonth {
                            LabeledContent("Busiest month", value: "\(busiestMonth.name) · \(busiestMonth.count) photos")
                        }
                        LabeledContent("Trips taken", value: "\(tripGroups.count)")
                        LabeledContent("Favorites", value: "\(allItems.filter(\.isFavorite).count)")
                    }
                }

                if !visitedFeatures.isEmpty {
                    Section {
                        Button {
                            showPassport = true
                        } label: {
                            Label("Open My Passport", systemImage: "book.closed.fill")
                                .font(.headline)
                        }
                        Button {
                            showQuiz = true
                        } label: {
                            Label("Play: Where Was This?", systemImage: "questionmark.app.fill")
                                .font(.headline)
                        }
                    }

                    Section("Year in Review") {
                        ForEach(photosPerYear.reversed(), id: \.year) { entry in
                            Button {
                                recap = yearRecap(for: entry.year)
                            } label: {
                                HStack {
                                    Text(String(entry.year))
                                        .font(.headline)
                                    Text("\(entry.count) memories · \(countriesInYear(entry.year)) countries")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(Color.appAccent)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Section("Continents") {
                        ForEach(continentBreakdown, id: \.name) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(entry.visited)/\(entry.total)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: Double(entry.visited), total: Double(entry.total))
                                    .tint(entry.visited > 0 ? Color.appAccent : .gray)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if !wishlistCountries.isEmpty {
                        Section("Wishlist") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(wishlistCountries) { country in
                                        VStack(spacing: 4) {
                                            Text(WorldGeometry.flag(for: country) ?? "🏳️")
                                                .font(.system(size: 34))
                                            Text(country.name)
                                                .font(.caption.bold())
                                                .lineLimit(1)
                                        }
                                        .frame(width: 104)
                                        .padding(.vertical, 10)
                                        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if !suggestions.isEmpty {
                        Section("Where next?") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(suggestions) { feature in
                                        VStack(spacing: 4) {
                                            Text(WorldGeometry.flag(for: feature) ?? "🏳️")
                                                .font(.system(size: 38))
                                            Text(feature.name)
                                                .font(.caption.bold())
                                                .lineLimit(1)
                                        }
                                        .frame(width: 110)
                                        .padding(.vertical, 12)
                                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if photosPerYear.count > 1 {
                    Section("Memories per year") {
                        Chart(photosPerYear, id: \.year) { entry in
                            BarMark(
                                x: .value("Year", String(entry.year)),
                                y: .value("Photos", entry.count)
                            )
                            .foregroundStyle(Color.appAccent.gradient)
                            .cornerRadius(4)
                        }
                        .frame(height: 220)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Stats")
            .sheet(isPresented: $showPassport) {
                PassportView(albums: albums)
            }
            .sheet(isPresented: $showQuiz) {
                QuizView(albums: albums)
            }
            .fullScreenCover(item: $recap) { recap in
                SlideshowView(
                    title: String(localized: "\(String(recap.year)) in Review"),
                    items: recap.items,
                    forceShuffle: true
                )
            }
        }
    }

    private func yearRecap(for year: Int) -> YearRecap {
        let calendar = Calendar.current
        let items = allItems.filter { calendar.component(.year, from: $0.createdTime) == year }
        return YearRecap(year: year, items: items)
    }

    private func countriesInYear(_ year: Int) -> Int {
        let calendar = Calendar.current
        let visited = albums.filter { album in
            album.items.contains { calendar.component(.year, from: $0.createdTime) == year }
        }
        return Set(visited.compactMap { WorldGeometry.feature(for: $0)?.id }).count
    }
}

/// Passport-style page of stamps: one per visited country with the year of
/// the first visit.
struct PassportView: View {
    let albums: [Album]
    @Environment(\.dismiss) private var dismiss

    private var stamps: [(feature: CountryFeature, name: String, year: Int)] {
        var seen = Set<String>()
        return albums.compactMap { album -> (CountryFeature, String, Int)? in
            guard let feature = WorldGeometry.feature(for: album),
                  seen.insert(feature.id).inserted,
                  let first = album.items.map(\.createdTime).min() else { return nil }
            return (feature, album.name, Calendar.current.component(.year, from: first))
        }
        .sorted { $0.2 < $1.2 }
    }

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 22)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(Array(stamps.enumerated()), id: \.element.feature.id) { i, stamp in
                        VStack(spacing: 6) {
                            Text(WorldGeometry.flag(for: stamp.feature) ?? "🌍")
                                .font(.system(size: 44))
                            Text(stamp.name.uppercased())
                                .font(.system(.subheadline, design: .serif).bold())
                                .multilineTextAlignment(.center)
                            Text(verbatim: "★ \(String(stamp.year)) ★")
                                .font(.system(.caption, design: .serif))
                        }
                        .foregroundStyle(stampColor(i))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(stampColor(i), style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
                        )
                        .rotationEffect(.degrees(Double((i * 7) % 11) - 5))
                        .padding(6)
                    }
                }
                .padding(24)
            }
            .background(Color(red: 0.96, green: 0.94, blue: 0.88))
            .navigationTitle(Text("My Passport"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
        }
    }

    private func stampColor(_ index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.55, green: 0.15, blue: 0.20),
            Color(red: 0.10, green: 0.30, blue: 0.55),
            Color(red: 0.15, green: 0.42, blue: 0.25),
            Color(red: 0.45, green: 0.25, blue: 0.55),
        ]
        return palette[index % palette.count]
    }
}

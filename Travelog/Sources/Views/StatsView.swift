import SwiftUI
import SwiftData
import Charts

/// Stats tab: travel numbers derived from the synced library.
struct StatsView: View {
    @Query private var albums: [Album]

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
                                .foregroundStyle(.orange)
                        }
                        ProgressView(value: Double(countriesVisited), total: Double(worldCountryCount))
                            .tint(.orange)
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
                    if let firstTrip, let latestTrip {
                        LabeledContent("First memory", value: firstTrip.formatted(.dateTime.month(.wide).year()))
                        LabeledContent("Latest memory", value: latestTrip.formatted(.dateTime.month(.wide).year()))
                    }
                }

                if !visitedFeatures.isEmpty {
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
                                    .tint(entry.visited > 0 ? .orange : .gray)
                            }
                            .padding(.vertical, 2)
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
                            .foregroundStyle(.orange.gradient)
                            .cornerRadius(4)
                        }
                        .frame(height: 220)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Stats")
        }
    }
}

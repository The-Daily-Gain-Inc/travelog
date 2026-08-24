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
        albums.filter { WorldGeometry.centroid(forCountryNamed: $0.name) != nil }.count
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

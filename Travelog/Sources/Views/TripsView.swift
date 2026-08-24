import SwiftUI
import SwiftData
import MapKit

struct Trip: Identifiable {
    let id: String
    let items: [MediaItem]

    var start: Date { items.first?.createdTime ?? .now }
    var end: Date { items.last?.createdTime ?? .now }

    var countries: [String] {
        var seen = Set<String>()
        return items.compactMap(\.album?.name).filter { seen.insert($0).inserted }
    }

    var route: [CLLocationCoordinate2D] {
        items.compactMap { item in
            guard let lat = item.latitude, let lon = item.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    var title: String {
        let calendar = Calendar.current
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return start.formatted(.dateTime.month(.wide).year())
        }
        return "\(start.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
    }
}

/// Trips tab: the library clustered into trips by gaps in shooting dates,
/// newest first — each with its route, countries and a photo strip.
struct TripsView: View {
    @Query private var albums: [Album]
    @State private var slideshowTrip: Trip?

    /// Splits the photo history wherever more than 14 days pass between shots.
    private var trips: [Trip] {
        let sorted = albums.flatMap(\.items)
            .filter { !$0.isHidden }
            .sorted { $0.createdTime < $1.createdTime }
        guard !sorted.isEmpty else { return [] }
        var result: [[MediaItem]] = [[]]
        var last: Date?
        for item in sorted {
            if let last, item.createdTime.timeIntervalSince(last) > 14 * 86_400 {
                result.append([])
            }
            result[result.count - 1].append(item)
            last = item.createdTime
        }
        return result
            .filter { !$0.isEmpty }
            .map { Trip(id: "\($0.first!.driveId)-\($0.count)", items: $0) }
            .reversed()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if trips.isEmpty {
                    ContentUnavailableView(
                        "No Trips Yet",
                        systemImage: "airplane",
                        description: Text("Trips appear once your albums are synced.")
                    )
                    .padding(.top, 120)
                } else {
                    LazyVStack(spacing: 20) {
                        ForEach(trips) { trip in
                            Button { slideshowTrip = trip } label: {
                                TripCard(trip: trip)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Trips")
            .fullScreenCover(item: $slideshowTrip) { trip in
                SlideshowView(title: trip.title, items: trip.items)
            }
        }
    }
}

struct TripCard: View {
    let trip: Trip
    @State private var thumbs: [UIImage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(trip.title)
                        .font(.title2.bold())
                    Text(trip.countries.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Label("\(trip.items.count) memories", systemImage: "photo.stack")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(18)
                Spacer(minLength: 0)
                tripMap
                    .frame(width: 280, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .task {
            guard thumbs.isEmpty else { return }
            for item in trip.items.filter({ !$0.isVideo }).prefix(4) {
                if let img = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name), maxPixel: 200) {
                    thumbs.append(img)
                }
            }
        }
    }

    @ViewBuilder
    private var tripMap: some View {
        if trip.route.isEmpty {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "map")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        } else {
            Map(initialPosition: .region(regionFitting(trip.route))) {
                if trip.route.count > 1 {
                    MapPolyline(coordinates: trip.route)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
                }
                if let first = trip.route.first {
                    Marker(trip.countries.first ?? "", coordinate: first).tint(.orange)
                }
            }
            .mapStyle(.imagery(elevation: .flat))
            .allowsHitTesting(false)
        }
    }

    private func regionFitting(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.6, 4),
                        longitudeDelta: max((maxLon - minLon) * 1.6, 4))
        )
    }
}
import SwiftUI
import SwiftData
import MapKit

struct CountryFeature: Identifiable {
    let id: String
    let name: String
    let polygons: [MKPolygon]
}

/// Loads the bundled world GeoJSON once per launch.
enum WorldGeometry {
    static let countries: [CountryFeature] = {
        guard let url = Bundle.main.url(forResource: "countries.geo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let objects = try? MKGeoJSONDecoder().decode(data) else { return [] }
        return objects.compactMap { obj in
            guard let feature = obj as? MKGeoJSONFeature else { return nil }
            var name = ""
            if let props = feature.properties,
               let dict = try? JSONSerialization.jsonObject(with: props) as? [String: Any] {
                name = dict["name"] as? String ?? ""
            }
            var polygons: [MKPolygon] = []
            for geo in feature.geometry {
                if let p = geo as? MKPolygon { polygons.append(p) }
                if let mp = geo as? MKMultiPolygon { polygons += mp.polygons }
            }
            guard !polygons.isEmpty, !name.isEmpty else { return nil }
            return CountryFeature(id: feature.identifier ?? name, name: name, polygons: polygons)
        }
    }()

    static func country(at coordinate: CLLocationCoordinate2D) -> CountryFeature? {
        let point = MKMapPoint(coordinate)
        return countries.first { feature in
            feature.polygons.contains { polygon in
                let renderer = MKPolygonRenderer(polygon: polygon)
                let p = renderer.point(for: point)
                return renderer.path?.contains(p) ?? false
            }
        }
    }

    /// Center of a country's mainland (largest polygon) — used for map markers.
    static func centroid(forCountryNamed name: String) -> CLLocationCoordinate2D? {
        guard let country = countries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
              let largest = country.polygons.max(by: {
                  $0.boundingMapRect.width * $0.boundingMapRect.height <
                  $1.boundingMapRect.width * $1.boundingMapRect.height
              }) else { return nil }
        let rect = largest.boundingMapRect
        return MKMapPoint(x: rect.midX, y: rect.midY).coordinate
    }
}

/// A group of photos taken near the same spot at the current zoom level.
struct PhotoCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let items: [MediaItem]
}

/// World Map tab: a satellite globe with two filters — Countries (visited
/// countries glow with album markers) and Photos (a pin per photo location,
/// grouped into clusters that split apart as you zoom in).
struct WorldMapView: View {
    enum MapMode: String, CaseIterable, Identifiable {
        case countries, photos
        var id: String { rawValue }
        var label: LocalizedStringKey { self == .countries ? "Countries" : "Photos" }
    }

    @Query private var albums: [Album]
    // Selectable for UI automation via the -initialMapMode launch argument.
    @State private var mode: MapMode =
        MapMode(rawValue: UserDefaults.standard.string(forKey: "initialMapMode") ?? "") ?? .countries
    @State private var selectedAlbum: Album?
    @State private var selectedCluster: PhotoCluster?
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)

    private var albumsByCountry: [String: Album] {
        Dictionary(albums.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var visitedCount: Int {
        albums.filter { WorldGeometry.centroid(forCountryNamed: $0.name) != nil }.count
    }

    private var locatedItems: [MediaItem] {
        albums.flatMap(\.items).filter { $0.latitude != nil && $0.longitude != nil }
    }

    /// Grid-clusters located photos; the cell size follows the visible span so
    /// clusters break apart naturally while zooming in.
    private var photoClusters: [PhotoCluster] {
        let cell = max(min(visibleSpan.latitudeDelta, visibleSpan.longitudeDelta) / 12, 0.0005)
        var buckets: [String: [MediaItem]] = [:]
        for item in locatedItems {
            guard let lat = item.latitude, let lon = item.longitude else { continue }
            let key = "\(Int((lat / cell).rounded()))|\(Int((lon / cell).rounded()))"
            buckets[key, default: []].append(item)
        }
        return buckets.map { key, items in
            let lat = items.compactMap(\.latitude).reduce(0, +) / Double(items.count)
            let lon = items.compactMap(\.longitude).reduce(0, +) / Double(items.count)
            return PhotoCluster(id: key, coordinate: .init(latitude: lat, longitude: lon), items: items)
        }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: .rect(.world)) {
                    if mode == .countries {
                        ForEach(WorldGeometry.countries) { country in
                            if albumsByCountry[country.name.lowercased()] != nil {
                                ForEach(Array(country.polygons.enumerated()), id: \.offset) { _, polygon in
                                    MapPolygon(polygon)
                                        .foregroundStyle(.orange.opacity(0.35))
                                        .stroke(.orange.opacity(0.9), lineWidth: 1.5)
                                }
                            }
                        }
                        ForEach(albums) { album in
                            if let coordinate = WorldGeometry.centroid(forCountryNamed: album.name) {
                                Annotation(album.name, coordinate: coordinate) {
                                    Button { selectedAlbum = album } label: {
                                        pinLabel(symbol: "photo.stack.fill", count: album.items.count)
                                    }
                                }
                            }
                        }
                    } else {
                        ForEach(photoClusters) { cluster in
                            Annotation(cluster.items.count == 1 ? cluster.items[0].album?.name ?? "" : "",
                                       coordinate: cluster.coordinate) {
                                Button { selectedCluster = cluster } label: {
                                    if cluster.items.count == 1 {
                                        Image(systemName: "photo.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(8)
                                            .background(.orange.gradient, in: Circle())
                                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                                    } else {
                                        pinLabel(symbol: "photo.on.rectangle.angled", count: cluster.items.count)
                                    }
                                }
                            }
                        }
                    }
                }
                .mapStyle(.imagery(elevation: .realistic))
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleSpan = context.region.span
                }
                .onTapGesture { screenPoint in
                    guard mode == .countries,
                          let coord = proxy.convert(screenPoint, from: .local),
                          let country = WorldGeometry.country(at: coord),
                          let album = albumsByCountry[country.name.lowercased()] else { return }
                    selectedAlbum = album
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                Picker("Map filter", selection: $mode) {
                    ForEach(MapMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
            }
            .overlay(alignment: .bottomLeading) {
                Group {
                    if mode == .countries {
                        Label("\(visitedCount) countries visited", systemImage: "airplane.departure")
                    } else {
                        Label("\(locatedItems.count) photos with location", systemImage: "mappin.and.ellipse")
                    }
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(20)
            }
            .navigationTitle("World Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(item: $selectedAlbum) { album in
                CountryGridView(album: album)
            }
            .sheet(item: $selectedCluster) { cluster in
                PhotoClusterSheet(cluster: cluster)
            }
        }
    }

    private func pinLabel(symbol: String, count: Int) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
            Text("\(count)")
                .font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

/// Thumbnails of every photo in a tapped map cluster.
struct PhotoClusterSheet: View {
    let cluster: PhotoCluster
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cluster.items.sorted { $0.createdTime < $1.createdTime }) { item in
                        ClusterThumbnail(item: item)
                    }
                }
                .padding(16)
            }
            .navigationTitle(Text("\(cluster.items.count) photos here"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
        }
    }
}

struct ClusterThumbnail: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if let album = item.album?.name {
                Text(album)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(6)
            }
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            guard !item.isVideo else { return }
            image = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
        }
    }
}

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

/// World Map tab: a satellite globe where visited countries glow and carry a
/// tappable marker with the photo count; tapping either opens the photo grid.
struct WorldMapView: View {
    @Query private var albums: [Album]
    @State private var selectedAlbum: Album?

    private var albumsByCountry: [String: Album] {
        Dictionary(albums.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var visitedCount: Int {
        albums.filter { WorldGeometry.centroid(forCountryNamed: $0.name) != nil }.count
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: .rect(.world)) {
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
                                    VStack(spacing: 2) {
                                        Image(systemName: "photo.stack.fill")
                                            .font(.system(size: 15, weight: .semibold))
                                        Text("\(album.items.count)")
                                            .font(.caption2.bold())
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 10))
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                                }
                            }
                        }
                    }
                }
                .mapStyle(.imagery(elevation: .realistic))
                .onTapGesture { screenPoint in
                    guard let coord = proxy.convert(screenPoint, from: .local),
                          let country = WorldGeometry.country(at: coord),
                          let album = albumsByCountry[country.name.lowercased()] else { return }
                    selectedAlbum = album
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomLeading) {
                Label("\(visitedCount) countries visited", systemImage: "airplane.departure")
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
        }
    }
}

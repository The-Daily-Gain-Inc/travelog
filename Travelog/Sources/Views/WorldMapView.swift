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
}

/// World Map tab: countries with albums are highlighted; tapping one opens its photo grid.
struct WorldMapView: View {
    @Query private var albums: [Album]
    @State private var selectedAlbum: Album?

    private var albumsByCountry: [String: Album] {
        Dictionary(albums.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(initialPosition: .rect(.world)) {
                    ForEach(WorldGeometry.countries) { country in
                        let visited = albumsByCountry[country.name.lowercased()] != nil
                        ForEach(Array(country.polygons.enumerated()), id: \.offset) { _, polygon in
                            MapPolygon(polygon)
                                .foregroundStyle(visited ? .orange.opacity(0.65) : .gray.opacity(0.18))
                                .stroke(visited ? Color.orange : Color.gray.opacity(0.4), lineWidth: visited ? 1.5 : 0.5)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .onTapGesture { screenPoint in
                    guard let coord = proxy.convert(screenPoint, from: .local),
                          let country = WorldGeometry.country(at: coord),
                          let album = albumsByCountry[country.name.lowercased()] else { return }
                    selectedAlbum = album
                }
            }
            .navigationTitle("World Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedAlbum) { album in
                CountryGridView(album: album)
            }
        }
    }
}

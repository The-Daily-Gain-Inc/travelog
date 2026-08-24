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

    /// Lowercased, diacritic-free, punctuation-free form used for matching.
    static func normalize(_ s: String) -> String {
        String(s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Common folder-name variants → canonical GeoJSON names.
    private static let aliases: [String: String] = [
        "usa": "United States of America", "us": "United States of America",
        "united states": "United States of America", "america": "United States of America",
        "uk": "United Kingdom", "britain": "United Kingdom", "great britain": "United Kingdom",
        "england": "United Kingdom", "scotland": "United Kingdom", "wales": "United Kingdom",
        "uae": "United Arab Emirates", "emirates": "United Arab Emirates",
        "dubai": "United Arab Emirates", "abu dhabi": "United Arab Emirates",
        "czechia": "Czech Republic",
        "holland": "Netherlands",
        "korea": "South Korea",
        "burma": "Myanmar",
        "tanzania": "United Republic of Tanzania",
        "drc": "Democratic Republic of the Congo",
        "congo": "Republic of the Congo",
        "north macedonia": "Macedonia",
        "cote d ivoire": "Ivory Coast", "cote divoire": "Ivory Coast",
    ]

    private static let byNormalizedName: [String: CountryFeature] =
        Dictionary(countries.map { (normalize($0.name), $0) }, uniquingKeysWith: { a, _ in a })

    /// Name-based lookup: normalized exact match, then alias table.
    static func feature(named name: String) -> CountryFeature? {
        let norm = normalize(name)
        if let hit = byNormalizedName[norm] { return hit }
        if let canonical = aliases[norm] { return byNormalizedName[normalize(canonical)] }
        return nil
    }

    /// Album → country: matches the album name first; if that fails, falls
    /// back to where the album's photos were actually taken (majority vote).
    /// Cached — the GPS fallback does point-in-polygon over every country.
    private static var albumFeatureCache: [String: String] = [:]

    static func feature(for album: Album) -> CountryFeature? {
        let cacheKey = "\(album.driveId)|\(album.name)|\(album.items.count)"
        if let id = albumFeatureCache[cacheKey] {
            return countries.first { $0.id == id }
        }
        var resolved = feature(named: album.name)
        if resolved == nil {
            let located = album.items
                .compactMap { item -> CLLocationCoordinate2D? in
                    guard let lat = item.latitude, let lon = item.longitude else { return nil }
                    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
                .prefix(25)
            var votes: [String: Int] = [:]
            for coord in located {
                if let hit = country(at: coord) { votes[hit.id, default: 0] += 1 }
            }
            if let winner = votes.max(by: { $0.value < $1.value })?.key {
                resolved = countries.first { $0.id == winner }
            }
        }
        if let resolved { albumFeatureCache[cacheKey] = resolved.id }
        return resolved
    }

    /// ISO alpha-3 (the GeoJSON ids) → alpha-2, for flag emoji.
    private static let iso3to2: [String: String] = [
        "AFG": "AF", "AGO": "AO", "ALB": "AL", "ARE": "AE", "ARG": "AR", "ARM": "AM",
        "ATA": "AQ", "ATF": "TF", "AUS": "AU", "AUT": "AT", "AZE": "AZ", "BDI": "BI",
        "BEL": "BE", "BEN": "BJ", "BFA": "BF", "BGD": "BD", "BGR": "BG", "BHS": "BS",
        "BIH": "BA", "BLR": "BY", "BLZ": "BZ", "BMU": "BM", "BOL": "BO", "BRA": "BR",
        "BRN": "BN", "BTN": "BT", "BWA": "BW", "CAF": "CF", "CAN": "CA", "CHE": "CH",
        "CHL": "CL", "CHN": "CN", "CIV": "CI", "CMR": "CM", "COD": "CD", "COG": "CG",
        "COL": "CO", "CRI": "CR", "CS-KM": "XK", "CUB": "CU", "CYP": "CY", "CZE": "CZ",
        "DEU": "DE", "DJI": "DJ", "DNK": "DK", "DOM": "DO", "DZA": "DZ", "ECU": "EC",
        "EGY": "EG", "ERI": "ER", "ESH": "EH", "ESP": "ES", "EST": "EE", "ETH": "ET",
        "FIN": "FI", "FJI": "FJ", "FLK": "FK", "FRA": "FR", "GAB": "GA", "GBR": "GB",
        "GEO": "GE", "GHA": "GH", "GIN": "GN", "GMB": "GM", "GNB": "GW", "GNQ": "GQ",
        "GRC": "GR", "GRL": "GL", "GTM": "GT", "GUF": "GF", "GUY": "GY", "HND": "HN",
        "HRV": "HR", "HTI": "HT", "HUN": "HU", "IDN": "ID", "IND": "IN", "IRL": "IE",
        "IRN": "IR", "IRQ": "IQ", "ISL": "IS", "ISR": "IL", "ITA": "IT", "JAM": "JM",
        "JOR": "JO", "JPN": "JP", "KAZ": "KZ", "KEN": "KE", "KGZ": "KG", "KHM": "KH",
        "KOR": "KR", "KWT": "KW", "LAO": "LA", "LBN": "LB", "LBR": "LR", "LBY": "LY",
        "LKA": "LK", "LSO": "LS", "LTU": "LT", "LUX": "LU", "LVA": "LV", "MAR": "MA",
        "MDA": "MD", "MDG": "MG", "MEX": "MX", "MKD": "MK", "MLI": "ML", "MLT": "MT",
        "MMR": "MM", "MNE": "ME", "MNG": "MN", "MOZ": "MZ", "MRT": "MR", "MWI": "MW",
        "MYS": "MY", "NAM": "NA", "NCL": "NC", "NER": "NE", "NGA": "NG", "NIC": "NI",
        "NLD": "NL", "NOR": "NO", "NPL": "NP", "NZL": "NZ", "OMN": "OM", "PAK": "PK",
        "PAN": "PA", "PER": "PE", "PHL": "PH", "PNG": "PG", "POL": "PL", "PRI": "PR",
        "PRK": "KP", "PRT": "PT", "PRY": "PY", "PSE": "PS", "QAT": "QA", "ROU": "RO",
        "RUS": "RU", "RWA": "RW", "SAU": "SA", "SDN": "SD", "SEN": "SN", "SLB": "SB",
        "SLE": "SL", "SLV": "SV", "SOM": "SO", "SRB": "RS", "SSD": "SS", "SUR": "SR",
        "SVK": "SK", "SVN": "SI", "SWE": "SE", "SWZ": "SZ", "SYR": "SY", "TCD": "TD",
        "TGO": "TG", "THA": "TH", "TJK": "TJ", "TKM": "TM", "TLS": "TL", "TTO": "TT",
        "TUN": "TN", "TUR": "TR", "TWN": "TW", "TZA": "TZ", "UGA": "UG", "UKR": "UA",
        "URY": "UY", "USA": "US", "UZB": "UZ", "VEN": "VE", "VNM": "VN", "VUT": "VU",
        "YEM": "YE", "ZAF": "ZA", "ZMB": "ZM", "ZWE": "ZW",
    ]

    /// Continent per ISO3 code (covering the bundled dataset).
    private static let continentByIso3: [String: String] = {
        var map: [String: String] = [:]
        let groups: [(String, [String])] = [
            ("Africa", ["AGO", "BDI", "BEN", "BFA", "BWA", "CAF", "CIV", "CMR", "COD", "COG",
                        "DJI", "DZA", "EGY", "ERI", "ESH", "ETH", "GAB", "GHA", "GIN", "GMB",
                        "GNB", "GNQ", "KEN", "LBR", "LBY", "LSO", "MAR", "MDG", "MLI", "MOZ",
                        "MRT", "MWI", "NAM", "NER", "NGA", "RWA", "SDN", "SEN", "SLE", "SOM",
                        "SSD", "SWZ", "TCD", "TGO", "TUN", "TZA", "UGA", "ZAF", "ZMB", "ZWE"]),
            ("Asia", ["AFG", "ARE", "ARM", "AZE", "BGD", "BRN", "BTN", "CHN", "CYP", "GEO",
                      "IDN", "IND", "IRN", "IRQ", "ISR", "JOR", "JPN", "KAZ", "KGZ", "KHM",
                      "KOR", "KWT", "LAO", "LBN", "LKA", "MMR", "MNG", "MYS", "NPL", "OMN",
                      "PAK", "PHL", "PRK", "PSE", "QAT", "SAU", "SYR", "THA", "TJK", "TKM",
                      "TLS", "TUR", "TWN", "UZB", "VNM", "YEM"]),
            ("Europe", ["ALB", "AUT", "BEL", "BGR", "BIH", "BLR", "CHE", "CS-KM", "CZE", "DEU",
                        "DNK", "ESP", "EST", "FIN", "FRA", "GBR", "GRC", "HRV", "HUN", "IRL",
                        "ISL", "ITA", "LTU", "LUX", "LVA", "MDA", "MKD", "MLT", "MNE", "NLD",
                        "NOR", "POL", "PRT", "ROU", "RUS", "SRB", "SVK", "SVN", "SWE", "UKR"]),
            ("North America", ["BHS", "BLZ", "BMU", "CAN", "CRI", "CUB", "DOM", "GRL", "GTM",
                               "HND", "HTI", "JAM", "MEX", "NIC", "PAN", "PRI", "SLV", "TTO", "USA"]),
            ("South America", ["ARG", "BOL", "BRA", "CHL", "COL", "ECU", "FLK", "GUF", "GUY",
                               "PER", "PRY", "SUR", "URY", "VEN"]),
            ("Oceania", ["AUS", "FJI", "NCL", "NZL", "PNG", "SLB", "VUT"]),
            ("Antarctica", ["ATA", "ATF"]),
        ]
        for (continent, codes) in groups {
            for code in codes { map[code] = continent }
        }
        return map
    }()

    static func continent(of feature: CountryFeature) -> String? {
        continentByIso3[feature.id]
    }

    static func flag(for feature: CountryFeature) -> String? {
        iso3to2[feature.id].flatMap { flag(iso2: $0) }
    }

    static func flag(iso2: String) -> String? {
        let scalars = iso2.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    static func centroid(of feature: CountryFeature) -> CLLocationCoordinate2D? {
        guard let largest = feature.polygons.max(by: {
            $0.boundingMapRect.width * $0.boundingMapRect.height <
            $1.boundingMapRect.width * $1.boundingMapRect.height
        }) else { return nil }
        let rect = largest.boundingMapRect
        return MKMapPoint(x: rect.midX, y: rect.midY).coordinate
    }

    /// Center of a country's mainland (largest polygon) — used for map markers.
    static func centroid(forCountryNamed name: String) -> CLLocationCoordinate2D? {
        feature(named: name).flatMap { centroid(of: $0) }
    }
}

/// Bridge that lets other screens (the idle Photo Frame timer) start the
/// map's World Tour.
@MainActor
final class TourController: ObservableObject {
    static let shared = TourController()
    @Published var tourRequested = false
    @Published var isTouring = false
    /// Album to fly to when the map appears ("Show on Map").
    @Published var focusAlbumId: String?
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
        case countries, regions, photos, heat
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .countries: "Countries"
            case .regions: "Regions"
            case .photos: "Photos"
            case .heat: "Heat"
            }
        }
    }

    @Query private var albums: [Album]
    // Selectable for UI automation via the -initialMapMode launch argument.
    @State private var mode: MapMode =
        MapMode(rawValue: UserDefaults.standard.string(forKey: "initialMapMode") ?? "") ?? .countries
    @State private var selectedAlbum: Album?
    @State private var selectedCluster: PhotoCluster?
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)
    @AppStorage("showTripLines") private var showTripLines = true
    @AppStorage("mapStyleChoice") private var mapStyleChoice = "globe"
    @AppStorage("tourSpeed") private var tourSpeed = 1.0
    @AppStorage("clusterDensity") private var clusterDensity = 12.0
    @AppStorage("wishlistIds") private var wishlistIdsRaw = ""

    private var wishlistIds: Set<String> {
        Set(wishlistIdsRaw.split(separator: ",").map(String.init))
    }

    private var currentMapStyle: MapStyle {
        switch mapStyleChoice {
        case "flatSat": .imagery(elevation: .flat)
        case "standard": .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case "hybrid": .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        default: .imagery(elevation: .realistic)
        }
    }

    /// Rect framing every located photo (used by pin-based modes).
    private var fitPinsRect: MKMapRect {
        var rect = MKMapRect.null
        for item in locatedItems {
            guard let lat = item.latitude, let lon = item.longitude else { continue }
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        guard !rect.isNull else { return .world }
        return rect.insetBy(dx: -rect.width * 0.25 - 200_000, dy: -rect.height * 0.25 - 200_000)
    }

    /// Camera rect that frames every visited country, slightly padded.
    private var fitRect: MKMapRect {
        var rect = MKMapRect.null
        for entry in albumFeatures {
            for polygon in entry.feature.polygons {
                rect = rect.union(polygon.boundingMapRect)
            }
        }
        guard !rect.isNull else { return .world }
        let padW = rect.width * 0.2, padH = rect.height * 0.2
        return rect.insetBy(dx: -padW, dy: -padH)
    }
    @AppStorage("slideDuration") private var slideDuration: Double = 5

    // World Tour: fly to a random country, play a short slideshow, repeat.
    @State private var camera: MapCameraPosition = .rect(.world)
    @State private var touring = false
    @State private var tourAlbum: Album?
    @State private var lastTourAlbumId: String?
    @State private var tourQueue: [String] = []
    @State private var tourTask: Task<Void, Never>?
    @State private var tourPath: [CLLocationCoordinate2D] = []
    @State private var lastTourCenter: CLLocationCoordinate2D?
    @State private var showVisitedList = false
    @State private var showCountrySearch = false
    @State private var tourStop = 0
    @State private var tourTotal = 0
    @State private var tourLegKm: Double?
    @State private var mapShareImage: UIImage?
    @State private var buildingShareImage = false
    @State private var tourCard: (album: Album, feature: CountryFeature)?
    @State private var tourRegionClusters: [PhotoCluster] = []
    @State private var tourCluster: PhotoCluster?
    @ObservedObject private var tourController = TourController.shared

    // Year filter ("All" + each year present in the library).
    @State private var selectedYear: Int?

    private func inYear(_ item: MediaItem) -> Bool {
        guard let selectedYear else { return true }
        return Calendar.current.component(.year, from: item.createdTime) == selectedYear
    }

    private var availableYears: [Int] {
        let calendar = Calendar.current
        return Set(albums.flatMap(\.items).map { calendar.component(.year, from: $0.createdTime) })
            .sorted(by: >)
    }

    private var yearAlbums: [Album] {
        selectedYear == nil ? albums : albums.filter { $0.items.contains(where: inYear) }
    }

    /// Resolved country per album (name match, alias, or GPS fallback).
    private var albumFeatures: [(album: Album, feature: CountryFeature)] {
        yearAlbums.compactMap { album in
            WorldGeometry.feature(for: album).map { (album, $0) }
        }
    }

    private var albumsByFeatureId: [String: Album] {
        Dictionary(albumFeatures.map { ($0.feature.id, $0.album) }, uniquingKeysWith: { a, _ in a })
    }

    private var visitedCount: Int {
        Set(albumFeatures.map(\.feature.id)).count
    }

    /// A stable, well-spread color per visited country (golden-ratio hues).
    private var colorByFeatureId: [String: Color] {
        let ids = Set(albumFeatures.map(\.feature.id)).sorted()
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { i, id in
            let hue = (Double(i) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            return (id, Color(hue: hue, saturation: 0.72, brightness: 0.92))
        })
    }

    private var locatedItems: [MediaItem] {
        albums.flatMap(\.items).filter {
            $0.latitude != nil && $0.longitude != nil && !$0.isHidden && inYear($0)
        }
    }

    /// Grid-clusters located photos; the cell size follows the visible span so
    /// clusters break apart naturally while zooming in.
    private var photoClusters: [PhotoCluster] {
        let cell = max(min(visibleSpan.latitudeDelta, visibleSpan.longitudeDelta) / clusterDensity, 0.0005)
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

    /// State/province-scale grouping of located photos for Regions mode.
    private var regionClusters: [PhotoCluster] {
        let cell = 1.5
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
                Map(position: $camera) {
                    if touring, tourPath.count == 2 {
                        MapPolyline(coordinates: tourPath)
                            .stroke(.white.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10, 8]))
                    }
                    if mode == .heat {
                        let maxCount = regionClusters.map(\.items.count).max() ?? 1
                        ForEach(regionClusters) { cluster in
                            let weight = Double(cluster.items.count) / Double(maxCount)
                            MapCircle(center: cluster.coordinate,
                                      radius: 120_000 + weight * 320_000)
                                .foregroundStyle(Color.appAccent.opacity(0.18 + weight * 0.45))
                            MapCircle(center: cluster.coordinate,
                                      radius: 40_000 + weight * 90_000)
                                .foregroundStyle(Color.appAccent.opacity(0.55 + weight * 0.4))
                        }
                    }
                    if mode == .regions {
                        ForEach(regionClusters) { cluster in
                            MapCircle(center: cluster.coordinate,
                                      radius: 60_000 + Double(min(cluster.items.count, 40)) * 2_000)
                                .foregroundStyle(Color.appAccent.opacity(0.3))
                                .stroke(Color.appAccent.opacity(0.85), lineWidth: 1.5)
                            Annotation("", coordinate: cluster.coordinate) {
                                Button { selectedCluster = cluster } label: {
                                    RegionBadge(cluster: cluster)
                                }
                            }
                        }
                    }
                    if mode == .countries {
                        // Wishlist countries: dashed-star gray pins.
                        ForEach(WorldGeometry.countries.filter { wishlistIds.contains($0.id) }) { country in
                            if let coordinate = WorldGeometry.centroid(of: country) {
                                Annotation(country.name, coordinate: coordinate) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(.gray.opacity(0.85), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.6),
                                                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                }
                            }
                        }
                        ForEach(albumFeatures, id: \.feature.id) { entry in
                            let tint = colorByFeatureId[entry.feature.id] ?? Color.appAccent
                            ForEach(Array(entry.feature.polygons.enumerated()), id: \.offset) { _, polygon in
                                MapPolygon(polygon)
                                    .foregroundStyle(tint.opacity(0.4))
                                    .stroke(tint.opacity(0.95), lineWidth: 1.5)
                            }
                            if let coordinate = WorldGeometry.centroid(of: entry.feature) {
                                Annotation(entry.album.name, coordinate: coordinate) {
                                    Button { selectedAlbum = entry.album } label: {
                                        pinLabel(
                                            flag: WorldGeometry.flag(for: entry.feature),
                                            count: entry.album.items.filter { inYear($0) && !$0.isHidden }.count,
                                            tint: tint
                                        )
                                    }
                                }
                            }
                        }
                    } else if mode == .photos {
                        if showTripLines {
                            ForEach(yearAlbums) { album in
                                let route = album.items
                                    .filter { $0.latitude != nil && $0.longitude != nil && !$0.isHidden && inYear($0) }
                                    .sorted { $0.createdTime < $1.createdTime }
                                    .map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) }
                                if route.count > 1 {
                                    MapPolyline(coordinates: route)
                                        .stroke(Color.appAccent.opacity(0.8),
                                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5]))
                                }
                            }
                        }
                        ForEach(photoClusters) { cluster in
                            Annotation(cluster.items.count == 1 ? cluster.items[0].album?.name ?? "" : "",
                                       coordinate: cluster.coordinate) {
                                Button { selectedCluster = cluster } label: {
                                    if cluster.items.count == 1 {
                                        Image(systemName: "photo.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(8)
                                            .background(Color.appAccent.gradient, in: Circle())
                                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                                    } else {
                                        pinLabel(symbol: "photo.on.rectangle.angled", count: cluster.items.count)
                                            .scaleEffect(min(1 + Double(cluster.items.count) / 30, 1.45))
                                    }
                                }
                            }
                        }
                    }
                }
                .mapStyle(currentMapStyle)
                .mapControls {
                    MapCompass()
                    MapPitchToggle()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleSpan = context.region.span
                }
                .onTapGesture { screenPoint in
                    guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                    switch mode {
                    case .countries:
                        if let country = WorldGeometry.country(at: coord),
                           let album = albumsByFeatureId[country.id] {
                            selectedAlbum = album
                        }
                    case .regions, .heat:
                        selectCluster(nearest: coord, in: regionClusters)
                    case .photos:
                        selectCluster(nearest: coord, in: photoClusters)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    topControls
                    if availableYears.count > 1 {
                        yearChips
                    }
                }
                .padding(.top, 8)
            }
            .overlay(alignment: .center) {
                if let card = tourCard {
                    TourNarrationCard(album: card.album, feature: card.feature,
                                      stop: tourStop, total: tourTotal, legKm: tourLegKm)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Group {
                    switch mode {
                    case .countries:
                        Button {
                            showVisitedList = true
                        } label: {
                            Label("\(visitedCount) countries visited", systemImage: "airplane.departure")
                        }
                    case .regions:
                        Label("\(regionClusters.count) areas explored", systemImage: "map")
                    case .photos:
                        Label("\(locatedItems.count) photos with location", systemImage: "mappin.and.ellipse")
                    case .heat:
                        Label("\(locatedItems.count) photos · heat by density", systemImage: "flame")
                    }
                }
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(20)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 12) {
                    if mode == .heat {
                        HStack(spacing: 8) {
                            Text("few").font(.caption2)
                            LinearGradient(colors: [Color.appAccent.opacity(0.2), Color.appAccent],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 90, height: 8)
                                .clipShape(Capsule())
                            Text("many").font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    Menu {
                        Picker("Map style", selection: $mapStyleChoice) {
                            Label("3D Globe", systemImage: "globe.americas.fill").tag("globe")
                            Label("Flat Satellite", systemImage: "map").tag("flatSat")
                            Label("Standard", systemImage: "map.fill").tag("standard")
                            Label("Hybrid", systemImage: "square.2.layers.3d").tag("hybrid")
                        }
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .help(Text("Map style"))
                    .accessibilityLabel(Text("Map style"))

                    Button {
                        withAnimation(.easeInOut(duration: 1.4)) {
                            camera = .rect(mode == .countries ? fitRect : fitPinsRect)
                        }
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .help(Text("Frame all my travels"))
                    .accessibilityLabel(Text("Frame all my travels"))

                    if let shareImage = mapShareImage {
                        ShareLink(
                            item: Image(uiImage: shareImage),
                            preview: SharePreview(Text("My Travel Map"), image: Image(uiImage: shareImage))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    } else {
                        Button {
                            Task { await buildMapShareImage() }
                        } label: {
                            Image(systemName: buildingShareImage ? "hourglass" : "square.and.arrow.up")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .disabled(buildingShareImage)
                        .help(Text("Share my travel map"))
                    }
                }
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
            .fullScreenCover(item: $tourAlbum, onDismiss: nextTourLeg) { album in
                SlideshowView(album: album, closeAtEnd: true)
            }
            .fullScreenCover(item: $tourCluster, onDismiss: nextTourLeg) { cluster in
                SlideshowView(
                    title: cluster.items.first?.album?.name ?? String(localized: "This area"),
                    items: cluster.items,
                    closeAtEnd: true
                )
            }
            .sheet(isPresented: $showCountrySearch) {
                CountrySearchSheet(
                    visited: albumFeatures,
                    wishlistRaw: $wishlistIdsRaw
                ) { feature in
                    showCountrySearch = false
                    if let center = WorldGeometry.centroid(of: feature) {
                        withAnimation(.easeInOut(duration: 1.6)) {
                            camera = .camera(MapCamera(centerCoordinate: center, distance: 2_600_000))
                        }
                    }
                }
            }
            .sheet(isPresented: $showVisitedList) {
                VisitedCountriesSheet(entries: albumFeatures) { album in
                    showVisitedList = false
                    selectedAlbum = album
                }
            }
            .onDisappear { stopTour() }
            .onAppear { consumeTourRequest(); consumeFocusRequest() }
            .onChange(of: tourController.tourRequested) { consumeTourRequest() }
            .onChange(of: tourController.focusAlbumId) { consumeFocusRequest() }
        }
    }

    private func consumeFocusRequest() {
        guard let id = tourController.focusAlbumId,
              let entry = albumFeatures.first(where: { $0.album.driveId == id }),
              let center = WorldGeometry.centroid(of: entry.feature) else { return }
        tourController.focusAlbumId = nil
        withAnimation(.easeInOut(duration: 1.8)) {
            camera = .camera(MapCamera(centerCoordinate: center, distance: 2_600_000))
        }
    }

    private func consumeTourRequest() {
        guard tourController.tourRequested else { return }
        tourController.tourRequested = false
        if !touring { startTour() }
    }

    /// Opens the cluster nearest to a map tap, if it's reasonably close
    /// (annotation buttons don't receive taps while the map has its own
    /// tap gesture, so hit-testing happens here).
    private func selectCluster(nearest coord: CLLocationCoordinate2D, in clusters: [PhotoCluster]) {
        guard !clusters.isEmpty else { return }
        let lonScale = max(cos(coord.latitude * .pi / 180), 0.2)
        func distance2(_ c: PhotoCluster) -> Double {
            let dLat = c.coordinate.latitude - coord.latitude
            let dLon = (c.coordinate.longitude - coord.longitude) * lonScale
            return dLat * dLat + dLon * dLon
        }
        guard let hit = clusters.min(by: { distance2($0) < distance2($1) }) else { return }
        let threshold = max(min(visibleSpan.latitudeDelta, visibleSpan.longitudeDelta) * 0.06, 0.02)
        if distance2(hit) < threshold * threshold {
            if mode == .regions {
                withAnimation(.easeInOut(duration: 1.2)) {
                    camera = .camera(MapCamera(centerCoordinate: hit.coordinate, distance: 1_400_000))
                }
            }
            selectedCluster = hit
        }
    }

    /// Renders a shareable world-map image: satellite base, visited countries
    /// filled in the accent color, flags at their centers, and a footer line.
    @MainActor
    private func buildMapShareImage() async {
        buildingShareImage = true
        defer { buildingShareImage = false }

        let options = MKMapSnapshotter.Options()
        options.mapType = .satellite
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 340)
        )
        options.size = CGSize(width: 1600, height: 1000)
        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            NSLog("Travelog map snapshot failed: %@", error.localizedDescription)
            return
        }

        let accent = UIColor(Color.appAccent)
        let renderer = UIGraphicsImageRenderer(size: options.size)
        mapShareImage = renderer.image { ctx in
            snapshot.image.draw(at: .zero)

            for entry in albumFeatures {
                for polygon in entry.feature.polygons {
                    let path = UIBezierPath()
                    let points = polygon.points()
                    guard polygon.pointCount > 2 else { continue }
                    for i in 0..<polygon.pointCount {
                        let point = snapshot.point(for: points[i].coordinate)
                        i == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    path.close()
                    accent.withAlphaComponent(0.45).setFill()
                    path.fill()
                    accent.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
                if let center = WorldGeometry.centroid(of: entry.feature),
                   let flag = WorldGeometry.flag(for: entry.feature) {
                    let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34)]
                    let str = NSAttributedString(string: flag, attributes: attrs)
                    var at = snapshot.point(for: center)
                    at.x -= str.size().width / 2
                    at.y -= str.size().height / 2
                    str.draw(at: at)
                }
            }

            let title = String(localized: "My Travelog · \(visitedCount) countries")
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let str = NSAttributedString(string: title, attributes: titleAttrs)
            str.draw(at: CGPoint(x: 40, y: options.size.height - str.size().height - 34))
        }
    }

    // MARK: - World Tour

    private func startTour() {
        guard !albumFeatures.isEmpty else { return }
        touring = true
        tourController.isTouring = true
        tourQueue = []
        // In Regions mode the tour hops areas instead of countries; snapshot
        // the clusters so camera movement doesn't reshuffle them mid-tour.
        tourRegionClusters = mode == .regions ? regionClusters : []
        tourTask = Task { await tourLeg(delay: 0.3) }
    }

    private func stopTour() {
        touring = false
        tourController.isTouring = false
        tourTask?.cancel()
        withAnimation { tourCard = nil }
        tourPath = []
        lastTourCenter = nil
        withAnimation(.easeInOut(duration: 1.5)) { camera = .rect(.world) }
    }

    private func nextTourLeg() {
        guard touring else { return }
        tourTask = Task {
            withAnimation(.easeInOut(duration: 1.5)) { camera = .rect(.world) }
            await tourLeg(delay: 2.2)
        }
    }

    @MainActor
    private func tourLeg(delay: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard touring, !Task.isCancelled else { return }
        // Traverse a shuffled queue so every stop plays once before any
        // repeats; reshuffle avoiding back-to-back duplicates at the seam.
        if !tourRegionClusters.isEmpty {
            await regionTourLeg()
            return
        }
        if tourQueue.isEmpty {
            var fresh = albumFeatures.map(\.album.driveId).shuffled()
            if fresh.count > 1, fresh.first == lastTourAlbumId {
                fresh.swapAt(0, fresh.count - 1)
            }
            tourQueue = fresh
            tourTotal = fresh.count
            tourStop = 0
        }
        guard !tourQueue.isEmpty else { stopTour(); return }
        let nextId = tourQueue.removeFirst()
        tourStop += 1
        guard let entry = albumFeatures.first(where: { $0.album.driveId == nextId }),
              let center = WorldGeometry.centroid(of: entry.feature) else {
            stopTour()
            return
        }
        lastTourAlbumId = entry.album.driveId
        if let previous = lastTourCenter {
            withAnimation { tourPath = [previous, center] }
            let a = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let b = CLLocation(latitude: center.latitude, longitude: center.longitude)
            tourLegKm = a.distance(from: b) / 1000
        } else {
            tourLegKm = nil
        }
        lastTourCenter = center
        withAnimation { tourCard = entry }
        withAnimation(.easeInOut(duration: 2.5 * tourSpeed)) {
            camera = .camera(MapCamera(centerCoordinate: center, distance: 2_600_000))
        }
        try? await Task.sleep(nanoseconds: UInt64(3_300_000_000 * tourSpeed))
        guard touring, !Task.isCancelled else { return }
        withAnimation { tourCard = nil }
        tourAlbum = entry.album
    }

    @MainActor
    private func regionTourLeg() async {
        if tourQueue.isEmpty {
            var fresh = tourRegionClusters.map(\.id).shuffled()
            if fresh.count > 1, fresh.first == lastTourAlbumId {
                fresh.swapAt(0, fresh.count - 1)
            }
            tourQueue = fresh
        }
        guard !tourQueue.isEmpty else { stopTour(); return }
        let nextId = tourQueue.removeFirst()
        guard let cluster = tourRegionClusters.first(where: { $0.id == nextId }) else {
            stopTour()
            return
        }
        lastTourAlbumId = cluster.id
        withAnimation(.easeInOut(duration: 2.5 * tourSpeed)) {
            camera = .camera(MapCamera(centerCoordinate: cluster.coordinate, distance: 900_000))
        }
        try? await Task.sleep(nanoseconds: UInt64(3_300_000_000 * tourSpeed))
        guard touring, !Task.isCancelled else { return }
        tourCluster = cluster
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            Picker("Map filter", selection: $mode) {
                ForEach(MapMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 420)

            Button {
                touring ? stopTour() : startTour()
            } label: {
                Image(systemName: touring ? "stop.circle.fill" : "airplane.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 34, height: 30)
                    .foregroundStyle(touring ? .red : Color.appAccent)
            }
            .help(touring ? Text("Stop the world tour") : Text("World tour: fly to a random country and play its photos"))

            Button {
                showCountrySearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .help(Text("Find a country / edit wishlist"))
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var yearChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                yearChip(label: String(localized: "All years"), year: nil)
                ForEach(availableYears, id: \.self) { year in
                    yearChip(label: String(year), year: year)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: 480)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func yearChip(label: String, year: Int?) -> some View {
        Button {
            withAnimation { selectedYear = year }
        } label: {
            Text(label)
                .font(.subheadline.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selectedYear == year ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.clear), in: Capsule())
                .foregroundStyle(selectedYear == year ? .white : .primary)
        }
    }

    private func pinLabel(symbol: String, count: Int) -> some View {
        pinBody(count: count, tint: Color.appAccent) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private func pinLabel(flag: String?, count: Int, tint: Color) -> some View {
        pinBody(count: count, tint: tint) {
            if let flag {
                Text(flag).font(.system(size: 22))
            } else {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
    }

    private func pinBody(count: Int, tint: Color, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 2) {
            icon()
            Text("\(count)")
                .font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

/// Search every country: fly to visited ones, star unvisited ones onto the
/// wishlist.
struct CountrySearchSheet: View {
    let visited: [(album: Album, feature: CountryFeature)]
    @Binding var wishlistRaw: String
    let onFly: (CountryFeature) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var wishlist: Set<String> {
        Set(wishlistRaw.split(separator: ",").map(String.init))
    }

    private var visitedIds: Set<String> { Set(visited.map(\.feature.id)) }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || WorldGeometry.normalize(name).contains(WorldGeometry.normalize(search))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Visited") {
                    ForEach(visited.filter { matches($0.album.name) }, id: \.feature.id) { entry in
                        Button {
                            onFly(entry.feature)
                        } label: {
                            HStack {
                                Text(WorldGeometry.flag(for: entry.feature) ?? "🏳️")
                                Text(entry.album.name)
                                Spacer()
                                Text("\(entry.album.items.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Wishlist — tap to star") {
                    ForEach(WorldGeometry.countries
                        .filter { !visitedIds.contains($0.id) && matches($0.name) }
                        .sorted { $0.name < $1.name }) { country in
                        Button {
                            var set = wishlist
                            if !set.insert(country.id).inserted { set.remove(country.id) }
                            wishlistRaw = set.sorted().joined(separator: ",")
                        } label: {
                            HStack {
                                Text(WorldGeometry.flag(for: country) ?? "🏳️")
                                Text(country.name)
                                Spacer()
                                Image(systemName: wishlist.contains(country.id) ? "star.fill" : "star")
                                    .foregroundStyle(wishlist.contains(country.id) ? .yellow : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $search, prompt: Text("Search countries"))
            .navigationTitle(Text("Countries"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
        }
    }
}

/// Overlay shown while the World Tour flies toward a country.
struct TourNarrationCard: View {
    let album: Album
    let feature: CountryFeature
    var stop = 0
    var total = 0
    var legKm: Double?

    private var dateRange: String? {
        let dates = album.items.map(\.createdTime)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let a = first.formatted(.dateTime.month(.abbreviated).year())
        let b = last.formatted(.dateTime.month(.abbreviated).year())
        return a == b ? a : "\(a) – \(b)"
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(WorldGeometry.flag(for: feature) ?? "🌍")
                .font(.system(size: 64))
            Text(album.name)
                .font(.title.bold())
            if let dateRange {
                Text(dateRange)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text("\(album.items.count) memories")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if stop > 0, total > 0 {
                HStack(spacing: 10) {
                    Text("Stop \(stop) of \(total)")
                    if let legKm, legKm >= 1 {
                        Label("\(Int(legKm.rounded()).formatted()) km", systemImage: "airplane")
                    }
                }
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .shadow(radius: 20)
    }
}

/// Modal listing every visited country with its flag; tapping opens the album.
struct VisitedCountriesSheet: View {
    let entries: [(album: Album, feature: CountryFeature)]
    let onSelect: (Album) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(entries.sorted { $0.album.name < $1.album.name }, id: \.feature.id) { entry in
                        let maxCount = entries.map(\.album.items.count).max() ?? 1
                        Button {
                            onSelect(entry.album)
                        } label: {
                            VStack(spacing: 6) {
                                Text(WorldGeometry.flag(for: entry.feature) ?? "🏳️")
                                    .font(.system(size: 52))
                                Text(entry.album.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("\(entry.album.items.count) photos")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ProgressView(value: Double(entry.album.items.count), total: Double(maxCount))
                                    .tint(Color.appAccent)
                                    .padding(.horizontal, 24)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle(Text("\(entries.count) countries visited"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
        }
    }
}

/// Region-mode marker: reverse-geocoded area name with a photo count.
struct RegionBadge: View {
    let cluster: PhotoCluster
    @State private var name: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(name ?? cluster.items.first?.album?.name ?? "…")
                .font(.caption.bold())
                .lineLimit(1)
            Text("\(cluster.items.count)")
                .font(.caption2.bold())
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.appAccent.gradient, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        .task {
            name = await PlaceLookup.shared.region(
                latitude: cluster.coordinate.latitude,
                longitude: cluster.coordinate.longitude
            )
        }
    }
}

/// Thumbnails of every photo in a tapped map cluster.
struct PhotoClusterSheet: View {
    let cluster: PhotoCluster
    @Environment(\.dismiss) private var dismiss
    @State private var showSlideshow = false
    @State private var startItem: MediaItem?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cluster.items.sorted { $0.createdTime < $1.createdTime }) { item in
                        Button { startItem = item } label: {
                            ClusterThumbnail(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle(Text("\(cluster.items.count) photos here"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSlideshow = true
                    } label: {
                        Label("Slideshow", systemImage: "play.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
            .fullScreenCover(isPresented: $showSlideshow) {
                SlideshowView(
                    title: cluster.items.first?.album?.name ?? String(localized: "This spot"),
                    items: cluster.items
                )
            }
            .fullScreenCover(item: $startItem) { item in
                SlideshowView(
                    title: cluster.items.first?.album?.name ?? String(localized: "This spot"),
                    items: cluster.items,
                    startItem: item
                )
            }
        }
    }
}

struct ClusterThumbnail: View {
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
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
        .contentShape(Rectangle())
        .task {
            guard !item.isVideo else { return }
            image = try? await MediaCache.shared.thumbnail(for: (item.driveId, item.name))
        }
    }
}

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
        case countries, regions, photos
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .countries: "Countries"
            case .regions: "Regions"
            case .photos: "Photos"
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

    private var currentMapStyle: MapStyle {
        switch mapStyleChoice {
        case "flatSat": .imagery(elevation: .flat)
        case "standard": .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case "hybrid": .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        default: .imagery(elevation: .realistic)
        }
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
    @State private var showVisitedList = false
    @ObservedObject private var tourController = TourController.shared

    /// Resolved country per album (name match, alias, or GPS fallback).
    private var albumFeatures: [(album: Album, feature: CountryFeature)] {
        albums.compactMap { album in
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
                    if mode == .regions {
                        ForEach(regionClusters) { cluster in
                            MapCircle(center: cluster.coordinate,
                                      radius: 60_000 + Double(min(cluster.items.count, 40)) * 2_000)
                                .foregroundStyle(.orange.opacity(0.3))
                                .stroke(.orange.opacity(0.85), lineWidth: 1.5)
                            Annotation("", coordinate: cluster.coordinate) {
                                Button { selectedCluster = cluster } label: {
                                    RegionBadge(cluster: cluster)
                                }
                            }
                        }
                    }
                    if mode == .countries {
                        ForEach(albumFeatures, id: \.feature.id) { entry in
                            let tint = colorByFeatureId[entry.feature.id] ?? .orange
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
                                            count: entry.album.items.count,
                                            tint: tint
                                        )
                                    }
                                }
                            }
                        }
                    } else if mode == .photos {
                        if showTripLines {
                            ForEach(albums) { album in
                                let route = album.items
                                    .filter { $0.latitude != nil && $0.longitude != nil }
                                    .sorted { $0.createdTime < $1.createdTime }
                                    .map { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) }
                                if route.count > 1 {
                                    MapPolyline(coordinates: route)
                                        .stroke(.orange.opacity(0.8),
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
                    case .regions:
                        selectCluster(nearest: coord, in: regionClusters)
                    case .photos:
                        selectCluster(nearest: coord, in: photoClusters)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                HStack(spacing: 10) {
                    Picker("Map filter", selection: $mode) {
                        ForEach(MapMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)

                    Button {
                        touring ? stopTour() : startTour()
                    } label: {
                        Image(systemName: touring ? "stop.circle.fill" : "airplane.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 34, height: 30)
                            .foregroundStyle(touring ? .red : .orange)
                    }
                    .help(touring ? Text("Stop the world tour") : Text("World tour: fly to a random country and play its photos"))
                }
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
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
                VStack(spacing: 12) {
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

                    Button {
                        withAnimation(.easeInOut(duration: 1.4)) { camera = .rect(fitRect) }
                    } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .help(Text("Frame all my travels"))
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
            .sheet(isPresented: $showVisitedList) {
                VisitedCountriesSheet(entries: albumFeatures) { album in
                    showVisitedList = false
                    selectedAlbum = album
                }
            }
            .onDisappear { stopTour() }
            .onAppear { consumeTourRequest() }
            .onChange(of: tourController.tourRequested) { consumeTourRequest() }
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
            selectedCluster = hit
        }
    }

    // MARK: - World Tour

    private func startTour() {
        guard !albumFeatures.isEmpty else { return }
        touring = true
        tourController.isTouring = true
        tourQueue = []
        tourTask = Task { await tourLeg(delay: 0.3) }
    }

    private func stopTour() {
        touring = false
        tourController.isTouring = false
        tourTask?.cancel()
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
        // Traverse a shuffled queue so every country plays once before any
        // repeats; reshuffle avoiding back-to-back duplicates at the seam.
        if tourQueue.isEmpty {
            var fresh = albumFeatures.map(\.album.driveId).shuffled()
            if fresh.count > 1, fresh.first == lastTourAlbumId {
                fresh.swapAt(0, fresh.count - 1)
            }
            tourQueue = fresh
        }
        guard !tourQueue.isEmpty else { stopTour(); return }
        let nextId = tourQueue.removeFirst()
        guard let entry = albumFeatures.first(where: { $0.album.driveId == nextId }),
              let center = WorldGeometry.centroid(of: entry.feature) else {
            stopTour()
            return
        }
        lastTourAlbumId = entry.album.driveId
        withAnimation(.easeInOut(duration: 2.5)) {
            camera = .camera(MapCamera(centerCoordinate: center, distance: 2_600_000))
        }
        try? await Task.sleep(nanoseconds: 3_300_000_000)
        guard touring, !Task.isCancelled else { return }
        tourAlbum = entry.album
    }

    private func pinLabel(symbol: String, count: Int) -> some View {
        pinBody(count: count, tint: .orange) {
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
        .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 10))
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

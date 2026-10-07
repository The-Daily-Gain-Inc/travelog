import Foundation
import SwiftData
import MapKit
import Vision
import UIKit

/// Names where a photo was taken and what it shows, from free signals:
///  - spot: the position reverse-geocoded to its area of interest, river/sea,
///    named place, street or district ("Stephansplatz", "Danube") — every
///    geotagged photo gets one;
///  - landmark: the monument / castle / bridge in the picture, from Apple
///    Maps' landmark places right next to the camera, or — when the on-device
///    image classifier sees a landmark-type subject — the closest place of
///    that kind a little farther out.
/// Both are stored on the MediaItem so each photo is examined once.
@MainActor
final class LandmarkLookup {
    static let shared = LandmarkLookup()

    private var inFlight: [String: Task<(String?, String?), Never>] = [:]
    private var backgroundPass: Task<Void, Never>?

    /// Classifier labels that mean "this is a landmark photo", mapped to the
    /// Maps search term used when the categorized lookup finds nothing nearby.
    nonisolated private static let subjectQueries: [String: String] = [
        "monument": "monument", "obelisk": "monument", "statue": "statue",
        "castle": "castle", "ruins": "ruins", "pyramid": "pyramid",
        "bridge": "bridge", "tower": "tower", "belltower": "tower",
        "clock_tower": "tower", "skyscraper": "tower", "lighthouse": "lighthouse",
        "dome": "cathedral", "arch": "arch", "fountain": "fountain",
        "museum": "museum", "stadium": "stadium", "theater": "theater",
        "waterfall": "waterfall", "canyon": "canyon", "volcano": "volcano",
        "glacier": "glacier"
    ]

    /// How far from the camera a candidate may be. Nearby landmarks are
    /// almost always shot from closer than this; anything farther is more
    /// likely a coincidence than the subject.
    nonisolated private static let radius: CLLocationDistance = 350

    /// Fills in the item's `spot` and `landmark` (either may stay nil) and
    /// marks it looked up so neither is computed twice. `image` is the
    /// already decoded photo the slideshow is displaying; nil for a video,
    /// which skips the classifier step.
    func resolve(_ item: MediaItem, image: UIImage?) async {
        if item.landmarkLookedUp { return }
        let id = item.driveId
        if let task = inFlight[id] { _ = await task.value; return }
        guard let lat = item.latitude, let lon = item.longitude else {
            item.landmarkLookedUp = true
            return
        }
        let knownSpot = item.spot
        let task = Task<(String?, String?), Never> {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            async let spot = knownSpot == nil ? Self.spot(at: coordinate) : knownSpot
            var landmark = await Self.landmarkAtCamera(coordinate)
            if landmark == nil, let image, let subject = await Self.landmarkSubject(in: image) {
                landmark = await Self.nearestLandmark(near: coordinate, subject: subject)
            }
            return (await spot, landmark)
        }
        inFlight[id] = task
        let (spot, landmark) = await task.value
        inFlight[id] = nil
        // The item may have been deleted by a sync while we were looking.
        if item.modelContext != nil {
            item.spot = spot
            // A landmark that is just the spot's name again adds nothing.
            item.landmark = landmark == spot ? nil : landmark
            item.landmarkLookedUp = true
        }
    }

    /// Geocode every photo that has no spot yet, in the background, so the
    /// name is there the moment any slideshow reaches it instead of a second
    /// later. Paced for the geocoder's rate limit; the monument refinement
    /// still runs once with the picture when it is shown, so this writes the
    /// spot but leaves `landmarkLookedUp` false. Restarted after each sync.
    func geotagAll(context: ModelContext) {
        backgroundPass?.cancel()
        backgroundPass = Task { [weak self] in
            let pending = (try? context.fetch(FetchDescriptor<MediaItem>(
                predicate: #Predicate { $0.spot == nil && !$0.landmarkLookedUp && $0.latitude != nil }
            ))) ?? []
            for item in pending {
                guard !Task.isCancelled, self != nil else { return }
                guard let lat = item.latitude, let lon = item.longitude, item.modelContext != nil else { continue }
                if let name = await Self.spot(at: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                    item.spot = name
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    /// The finest named thing the geocoder knows at this position. The
    /// placemark's `name` is skipped when it is just a street address.
    nonisolated private static func spot(at coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let name = mark.name.flatMap { $0.rangeOfCharacter(from: .decimalDigits) == nil ? $0 : nil }
        let candidates = [mark.areasOfInterest?.first, mark.inlandWater, mark.ocean,
                          name, mark.thoroughfare, mark.subLocality]
        return candidates.compactMap { $0 }.first { $0 != mark.locality && $0 != mark.country }
    }

    /// The strongest landmark-type label the classifier is confident about,
    /// or nil when the photo is of something else (people, food, a street…).
    nonisolated private static func landmarkSubject(in image: UIImage) async -> String? {
        guard let cg = image.cgImage else { return nil }
        return await Task.detached(priority: .utility) { () -> String? in
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
            guard (try? handler.perform([request])) != nil,
                  let results = request.results else { return nil }
            // Only labels the model is precise about; the raw confidences are
            // tiny for everything but the obvious.
            let confident = results.filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            return confident
                .sorted { $0.confidence > $1.confidence }
                .first { subjectQueries[$0.identifier] != nil }?
                .identifier
        }.value
    }

    nonisolated private static func nearest(_ items: [MKMapItem], to center: CLLocationCoordinate2D,
                                            within limit: CLLocationDistance) -> String? {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return items.compactMap { item -> (String, CLLocationDistance)? in
            guard let name = item.name, !name.isEmpty, let loc = item.placemark.location else { return nil }
            let d = loc.distance(from: origin)
            return d <= limit ? (name, d) : nil
        }
        .min { $0.1 < $1.1 }?.0
    }

    nonisolated private static var landmarkCategories: [MKPointOfInterestCategory] {
        var categories: [MKPointOfInterestCategory] = [.museum, .nationalPark, .stadium, .amusementPark, .zoo, .aquarium]
        if #available(iOS 18.0, *) {
            categories += [.landmark, .nationalMonument, .castle, .fortress]
        }
        return categories
    }

    /// A Maps landmark the camera was standing at (within 150 m) — close
    /// enough that it is the subject whatever the picture looks like, so no
    /// classifier is needed. Runs for videos too.
    nonisolated private static func landmarkAtCamera(_ center: CLLocationCoordinate2D) async -> String? {
        let limit: CLLocationDistance = 150
        let poi = await MKLocalPointsOfInterestRequest(center: center, radius: limit)
        poi.pointOfInterestFilter = MKPointOfInterestFilter(including: landmarkCategories)
        guard let response = try? await MKLocalSearch(request: poi).start() else { return nil }
        return nearest(response.mapItems, to: center, within: limit)
    }

    /// Closest landmark a little farther out, allowed because the classifier
    /// saw one in the picture: first among Maps' landmark categories, then by
    /// searching Maps for the subject the classifier saw ("bridge",
    /// "cathedral") so places Maps doesn't categorize as landmarks still
    /// resolve.
    nonisolated private static func nearestLandmark(near center: CLLocationCoordinate2D,
                                                    subject: String) async -> String? {
        let poi = await MKLocalPointsOfInterestRequest(center: center, radius: radius)
        poi.pointOfInterestFilter = MKPointOfInterestFilter(including: landmarkCategories)
        if let response = try? await MKLocalSearch(request: poi).start(),
           let name = nearest(response.mapItems, to: center, within: radius) {
            return name
        }

        guard let query = subjectQueries[subject] else { return nil }
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = query
        search.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        search.resultTypes = .pointOfInterest
        guard let response = try? await MKLocalSearch(request: search).start() else { return nil }
        return nearest(response.mapItems, to: center, within: radius)
    }
}

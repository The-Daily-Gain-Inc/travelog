import Foundation
import MapKit
import Vision
import UIKit

/// Names the monument in a photo, when there is one, from two free signals:
/// Apple's on-device image classifier says whether the picture even shows a
/// landmark-type subject (castle, bridge, statue, cathedral…), and only then
/// does Apple Maps get asked for the closest such place to where the photo
/// was taken. The classifier gate is what keeps a selfie or a lunch shot taken
/// beside the Colosseum from being labelled "Colosseum". Photos without GPS,
/// or whose subject isn't a landmark, get nothing — better blank than wrong.
/// Results are stored on the MediaItem so each photo is examined once.
@MainActor
final class LandmarkLookup {
    static let shared = LandmarkLookup()

    private var inFlight: [String: Task<String?, Never>] = [:]

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

    /// Returns the landmark name, writing the answer (or the absence of one)
    /// onto the item so it is never computed twice. `image` is the already
    /// decoded photo the slideshow is displaying.
    func landmark(for item: MediaItem, image: UIImage) async -> String? {
        if item.landmarkLookedUp { return item.landmark }
        let id = item.driveId
        if let task = inFlight[id] { return await task.value }
        guard let lat = item.latitude, let lon = item.longitude else {
            item.landmarkLookedUp = true
            return nil
        }
        let task = Task<String?, Never> {
            guard let subject = await Self.landmarkSubject(in: image) else { return nil }
            return await Self.nearestLandmark(
                near: CLLocationCoordinate2D(latitude: lat, longitude: lon), subject: subject)
        }
        inFlight[id] = task
        let name = await task.value
        inFlight[id] = nil
        // The item may have been deleted by a sync while we were looking.
        if item.modelContext != nil {
            item.landmark = name
            item.landmarkLookedUp = true
        }
        return name
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

    /// Closest landmark to the camera position: first among Maps' landmark
    /// categories, then by searching Maps for the subject the classifier saw
    /// ("bridge", "cathedral") so places Maps doesn't categorize as landmarks
    /// still resolve.
    nonisolated private static func nearestLandmark(near center: CLLocationCoordinate2D,
                                                    subject: String) async -> String? {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        func nearest(_ items: [MKMapItem]) -> String? {
            items.compactMap { item -> (String, CLLocationDistance)? in
                guard let name = item.name, !name.isEmpty, let loc = item.placemark.location else { return nil }
                let d = loc.distance(from: origin)
                return d <= radius ? (name, d) : nil
            }
            .min { $0.1 < $1.1 }?.0
        }

        var categories: [MKPointOfInterestCategory] = [.museum, .nationalPark, .stadium, .amusementPark, .zoo, .aquarium]
        if #available(iOS 18.0, *) {
            categories += [.landmark, .nationalMonument, .castle, .fortress]
        }
        let poi = await MKLocalPointsOfInterestRequest(center: center, radius: radius)
        poi.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        if let response = try? await MKLocalSearch(request: poi).start(),
           let name = nearest(response.mapItems) {
            return name
        }

        guard let query = subjectQueries[subject] else { return nil }
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = query
        search.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        search.resultTypes = .pointOfInterest
        guard let response = try? await MKLocalSearch(request: search).start() else { return nil }
        return nearest(response.mapItems)
    }
}

import Foundation
import CoreLocation
import SwiftUI

extension Color {
    /// User-selected accent, used for controls and map artwork alike.
    static var appAccent: Color {
        switch UserDefaults.standard.string(forKey: "accentTheme") {
        case "blue": .blue
        case "green": .green
        case "pink": .pink
        case "teal": .teal
        default: .orange
        }
    }
}

/// Reverse-geocodes photo GPS positions into "City, Country" captions,
/// caching by rounded coordinate to stay well under geocoder rate limits.
@MainActor
final class PlaceLookup {
    static let shared = PlaceLookup()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    private var pending: [String: Task<String?, Never>] = [:]

    /// Region-level name with country flag ("🇩🇪 Bavaria", "🇯🇵 Kyoto").
    /// Prefers the state/province, then county, then city, then country.
    func region(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "r|%.1f|%.1f", latitude, longitude)
        if let hit = cache[key] { return hit }
        if let pending = pending[key] { return await pending.value }
        let task = Task<String?, Never> {
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
            let name = mark.administrativeArea
                ?? mark.subAdministrativeArea
                ?? mark.locality
                ?? mark.country
            guard let name else { return nil }
            if let iso2 = mark.isoCountryCode, let flag = WorldGeometry.flag(iso2: iso2) {
                return "\(flag) \(name)"
            }
            return name
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result { cache[key] = result }
        return result
    }

    func place(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.2f|%.2f", latitude, longitude)
        if let hit = cache[key] { return hit }
        if let pending = pending[key] { return await pending.value }

        let task = Task<String?, Never> {
            let location = CLLocation(latitude: latitude, longitude: longitude)
            guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
            let city = mark.locality ?? mark.administrativeArea
            let parts = [city, mark.country].compactMap(\.self)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result { cache[key] = result }
        return result
    }
}

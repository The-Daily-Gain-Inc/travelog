import Foundation
import SwiftData
import UIKit

/// Demo-mode data: seeds albums + placeholder photos so the whole app can be
/// exercised without a Google account. Mock media ids are prefixed "mock-" and
/// MediaCache renders them locally instead of hitting Drive.
enum MockData {
    static let idPrefix = "mock-"

    static let countries: [(name: String, flag: String, photos: Int)] = [
        ("Japan", "🇯🇵", 14), ("Italy", "🇮🇹", 11), ("Brazil", "🇧🇷", 9),
        ("Canada", "🇨🇦", 12), ("Australia", "🇦🇺", 8), ("Egypt", "🇪🇬", 7),
        ("Iceland", "🇮🇸", 10), ("Thailand", "🇹🇭", 13), ("Peru", "🇵🇪", 6),
        ("Morocco", "🇲🇦", 9),
    ]

    @MainActor
    static func seed(into context: ModelContext) throws {
        // Wipe any previous mock rows, then reseed.
        let existing = try context.fetch(FetchDescriptor<Album>())
        for album in existing where album.driveId.hasPrefix(idPrefix) {
            context.delete(album)
        }
        for (name, _, photoCount) in countries {
            let album = Album(driveId: idPrefix + name.lowercased(), name: name)
            context.insert(album)
            for i in 1...photoCount {
                let item = MediaItem(
                    driveId: "\(idPrefix)\(name.lowercased())-\(i)",
                    name: "\(name) \(i).jpg",
                    mimeType: "image/jpeg",
                    createdTime: Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 86_400),
                    sizeBytes: 0
                )
                item.album = album
                context.insert(item)
            }
        }
        try context.save()
    }

    /// Deterministic, pleasant-looking placeholder photo for a mock media id.
    static func renderImage(for driveId: String, size: CGSize = CGSize(width: 1600, height: 1200)) -> UIImage {
        let seed = driveId.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = CGFloat(seed % 360) / 360
        let country = countries.first { driveId.contains($0.name.lowercased()) }
        let index = driveId.split(separator: "-").last.map(String.init) ?? ""

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors = [
                UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor,
                UIColor(hue: fmod(hue + 0.12, 1), saturation: 0.65, brightness: 0.45, alpha: 1).cgColor,
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: size.width, y: size.height), options: [])
            // Simple "mountain" silhouette for texture.
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: size.height))
            var x: CGFloat = 0
            var rng = seed
            while x < size.width {
                rng = (rng &* 1103515245 &+ 12345) & 0x7FFFFFFF
                let peak = size.height * (0.45 + CGFloat(rng % 40) / 100)
                x += size.width / 6
                path.addLine(to: CGPoint(x: x - size.width / 12, y: peak))
                path.addLine(to: CGPoint(x: x, y: size.height * 0.85))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.close()
            UIColor(white: 0, alpha: 0.25).setFill()
            path.fill()

            let flag = country?.flag ?? "📷"
            let title = "\(flag)  \(country?.name ?? "Photo") \(index)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.height * 0.08, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
            let str = NSAttributedString(string: title, attributes: attrs)
            let strSize = str.size()
            str.draw(at: CGPoint(x: (size.width - strSize.width) / 2,
                                 y: (size.height - strSize.height) / 2))
        }
    }
}

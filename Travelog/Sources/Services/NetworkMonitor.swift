import Foundation
import Network

/// Tracks whether the current network path is "expensive" (cellular/hotspot)
/// so downloads can be limited to Wi-Fi when the user asks.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "travelog.network-monitor")
    private(set) var isExpensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isExpensive = path.isExpensive
        }
        monitor.start(queue: queue)
    }
}

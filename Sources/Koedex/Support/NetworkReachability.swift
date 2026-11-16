import Foundation
import Network

enum NetworkReachabilityState { case online, offline, unknown }

enum OfflineCleanupPolicy {
    static func shouldInstantInsert(enabled: Bool, eligible: Bool) -> Bool { enabled && eligible }
    static func shouldSkipCleanup(state: NetworkReachabilityState) -> Bool { state == .offline }
}

@MainActor
final class NetworkReachability {
    private let monitor = NWPathMonitor()
    private(set) var state: NetworkReachabilityState = .unknown

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let state: NetworkReachabilityState
            switch path.status {
            case .satisfied: state = .online
            case .unsatisfied: state = .offline
            default: state = .unknown
            }
            MainActor.assumeIsolated { self?.state = state }
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}

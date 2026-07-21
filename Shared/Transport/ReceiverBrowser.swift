import Foundation
import Network

/// A Mac receiver discovered via Bonjour.
public struct DiscoveredReceiver {
    public let name: String
    public let endpoint: NWEndpoint
}

/// Browses for Mac receivers advertising the External Screen Bonjour service.
public final class ReceiverBrowser {

    public var onResultsChanged: (([DiscoveredReceiver]) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.externalscreen.network.browser")

    public init() {}

    public func start() {
        let browser = NWBrowser(
            for: .bonjour(type: ExternalScreenConstants.bonjourServiceType, domain: nil),
            using: NetworkConnection.makeParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let receivers = results.compactMap { result -> DiscoveredReceiver? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredReceiver(name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                self?.onResultsChanged?(receivers)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

import Foundation
import Network

/// Wraps an NWConnection with protocol message framing.
/// Send: writes header+payload as-is. Receive: reassembles messages via MessageDeframer.
final class NetworkConnection {

    let connection: NWConnection
    private let deframer = MessageDeframer()

    var onMessage: ((Data) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    /// Low-latency TCP parameters used by both host and receiver sides.
    static func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .interactiveVideo
        return params
    }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("NetworkConnection: send error: \(error)")
            }
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                for message in self.deframer.append(data) {
                    self.onMessage?(message)
                }
            }

            if isComplete || error != nil {
                self.connection.cancel()
                self.onStateChange?(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }
}

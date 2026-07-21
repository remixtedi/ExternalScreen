import Foundation
import Network

/// Receiver-side transport: listens on TCP port 2346, advertises itself
/// via Bonjour, and accepts a single host connection.
public final class NetworkReceiverTransport: FrameTransport {

    public weak var transportDelegate: FrameTransportDelegate?

    private var listener: NWListener?
    private var networkConnection: NetworkConnection?
    private let flowControl = FlowControlState()
    private let queue = DispatchQueue(label: "com.externalscreen.network.receiver")
    private var connected = false
    private let lock = NSLock()
    private let serviceName: String

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    public func start() throws {
        let listener = try NWListener(
            using: NetworkConnection.makeParameters(),
            on: NWEndpoint.Port(rawValue: ExternalScreenConstants.networkPort)!
        )
        listener.service = NWListener.Service(
            name: serviceName,
            type: ExternalScreenConstants.bonjourServiceType
        )
        listener.newConnectionHandler = { [weak self] nwConnection in
            self?.accept(nwConnection)
        }
        listener.stateUpdateHandler = { state in
            print("NetworkReceiverTransport: listener state \(state)")
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        disconnect()
        listener?.cancel()
        listener = nil
    }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    public var droppedFrameCount: UInt64 { flowControl.droppedFrameCount }

    public func sendMessage(type: MessageType, payload: Data) {
        let header = MessageHeader(
            type: type,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000_000),
            payloadLength: UInt32(payload.count)
        )
        var message = header.toData()
        message.append(payload)

        lock.lock()
        let conn = networkConnection
        lock.unlock()
        conn?.send(message)
    }

    public func sendFrame(frameData: Data, frameNumber: UInt32, isKeyframe: Bool, presentationTime: UInt64) {
        // Receiver never streams video; present for FrameTransport conformance.
    }

    public func canSendFrame() -> Bool { true }

    public func incrementDroppedFrames() {}

    public func resetFlowControl() { flowControl.reset() }

    public func disconnect() {
        lock.lock()
        let conn = networkConnection
        networkConnection = nil
        connected = false
        lock.unlock()
        conn?.cancel()
    }

    private func accept(_ nwConnection: NWConnection) {
        let conn = NetworkConnection(connection: nwConnection)

        // Replace any existing connection (matches iPad-side behavior)
        lock.lock()
        let previous = networkConnection
        networkConnection = conn
        lock.unlock()
        previous?.cancel()

        conn.onMessage = { [weak self] message in
            guard let self = self else { return }
            self.transportDelegate?.transport(self, didReceive: message)
        }
        conn.onStateChange = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                // A stale connection (superseded by a later `accept()` call) must not
                // flip shared state even on `.ready` — otherwise a slow-to-connect
                // connection A can "reconnect" after connection B already replaced it.
                guard conn === self.networkConnection else {
                    self.lock.unlock()
                    return
                }
                let wasConnected = self.connected
                self.connected = true
                self.lock.unlock()
                guard !wasConnected else { return }
                DispatchQueue.main.async {
                    self.transportDelegate?.transportDidConnect(self, endpointName: "Host Mac")
                }
            case .failed, .cancelled:
                self.lock.lock()
                // Same identity guard: a stale connection A's later `.failed`/`.cancelled`
                // must not clear `networkConnection` (now pointing at B) or fire
                // transportDidDisconnect for a session that's actually still live.
                guard conn === self.networkConnection else {
                    self.lock.unlock()
                    return
                }
                let wasConnected = self.connected
                self.connected = false
                self.networkConnection = nil
                self.lock.unlock()
                if wasConnected {
                    DispatchQueue.main.async {
                        self.transportDelegate?.transportDidDisconnect(self)
                    }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }
}

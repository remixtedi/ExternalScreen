import Foundation
import Network

/// Host-side transport: connects to a discovered Mac receiver over TCP
/// (Thunderbolt Bridge when cable-connected) and streams frames to it.
public final class NetworkHostTransport: FrameTransport {

    public weak var transportDelegate: FrameTransportDelegate?

    private let endpoint: NWEndpoint
    private let endpointName: String
    private var networkConnection: NetworkConnection?
    private let flowControl = FlowControlState()
    private let queue = DispatchQueue(label: "com.externalscreen.network.host")
    private var connected = false

    public init(endpoint: NWEndpoint, name: String) {
        self.endpoint = endpoint
        self.endpointName = name
    }

    public func start() {
        let nwConnection = NWConnection(to: endpoint, using: NetworkConnection.makeParameters())
        let conn = NetworkConnection(connection: nwConnection)
        networkConnection = conn

        conn.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        conn.onStateChange = { [weak self] state in
            self?.handleStateChange(state)
        }
        conn.start(queue: queue)
    }

    public var isConnected: Bool { connected }

    public var droppedFrameCount: UInt64 { flowControl.droppedFrameCount }

    public func sendMessage(type: MessageType, payload: Data) {
        let header = MessageHeader(
            type: type,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000_000),
            payloadLength: UInt32(payload.count)
        )
        var message = header.toData()
        message.append(payload)
        networkConnection?.send(message)
    }

    public func sendFrame(frameData: Data, frameNumber: UInt32, isKeyframe: Bool, presentationTime: UInt64) {
        let frameHeader = FrameDataHeader(
            frameNumber: frameNumber,
            isKeyframe: isKeyframe,
            presentationTime: presentationTime
        )
        var payload = frameHeader.toData()
        payload.append(frameData)
        sendMessage(type: .frameData, payload: payload)
        flowControl.recordSent(frameNumber)
    }

    public func canSendFrame() -> Bool {
        flowControl.canSend(maxInFlight: ExternalScreenConstants.maxInFlightFrames)
    }

    public func incrementDroppedFrames() { flowControl.recordDropped() }

    public func resetFlowControl() { flowControl.reset() }

    public func disconnect() {
        networkConnection?.cancel()
        networkConnection = nil
        connected = false
    }

    private func handleMessage(_ message: Data) {
        // Fast path: consume frame acks for flow control (matches PeerTalk transport behavior)
        if message.count >= MessageHeader.size {
            let typeRaw = message.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            if typeRaw == MessageType.frameAck.rawValue {
                let payload = message.subdata(in: MessageHeader.size..<message.count)
                if let ack = FrameAckMessage.from(data: payload) {
                    flowControl.recordAck(ack.frameNumber)
                }
                return
            }
        }
        transportDelegate?.transport(self, didReceive: message)
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connected = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.transportDelegate?.transportDidConnect(self, endpointName: self.endpointName)
            }
        case .failed, .cancelled:
            let wasConnected = connected
            connected = false
            if wasConnected {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.transportDelegate?.transportDidDisconnect(self)
                }
            }
        default:
            break
        }
    }
}

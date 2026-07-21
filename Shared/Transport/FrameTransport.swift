import Foundation

/// Delegate for transport-level connection and message events.
/// `didReceive data` delivers a complete protocol message: 16-byte MessageHeader + payload.
/// Frame acks are consumed internally by transports for flow control and are NOT forwarded.
public protocol FrameTransportDelegate: AnyObject {
    func transportDidConnect(_ transport: FrameTransport, endpointName: String)
    func transportDidDisconnect(_ transport: FrameTransport)
    func transport(_ transport: FrameTransport, didReceive data: Data)
}

/// Abstraction over PeerTalk (iPad) and TCP/Thunderbolt Bridge (Mac) transports.
public protocol FrameTransport: AnyObject {
    var transportDelegate: FrameTransportDelegate? { get set }
    var isConnected: Bool { get }
    var droppedFrameCount: UInt64 { get }
    func sendMessage(type: MessageType, payload: Data)
    func sendFrame(frameData: Data, frameNumber: UInt32, isKeyframe: Bool, presentationTime: UInt64)
    func canSendFrame() -> Bool
    func incrementDroppedFrames()
    func resetFlowControl()
    func disconnect()
}

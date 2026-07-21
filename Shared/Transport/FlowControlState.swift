import Foundation

/// Thread-safe ack-based flow control state, shared by all transports.
public final class FlowControlState {

    private var lastSentFrameNumber: UInt32 = 0
    private var lastAckedFrameNumber: UInt32 = 0
    private var dropped: UInt64 = 0
    private let lock = NSLock()

    public init() {}

    public func recordSent(_ frameNumber: UInt32) {
        lock.lock()
        lastSentFrameNumber = frameNumber
        lock.unlock()
    }

    public func recordAck(_ frameNumber: UInt32) {
        lock.lock()
        // Only advance forward (handle wrap-around with unsigned comparison)
        if frameNumber &- lastAckedFrameNumber < 0x8000_0000 {
            lastAckedFrameNumber = frameNumber
        }
        lock.unlock()
    }

    public func canSend(maxInFlight: UInt32) -> Bool {
        lock.lock()
        let inFlight = lastSentFrameNumber &- lastAckedFrameNumber
        lock.unlock()
        return inFlight <= maxInFlight
    }

    public func recordDropped() {
        lock.lock()
        dropped += 1
        lock.unlock()
    }

    public var droppedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func reset() {
        lock.lock()
        lastSentFrameNumber = 0
        lastAckedFrameNumber = 0
        dropped = 0
        lock.unlock()
    }
}

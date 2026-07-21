import Foundation

/// Reassembles length-delimited protocol messages from a TCP byte stream.
/// Not thread-safe; call from a single receive queue.
public final class MessageDeframer {

    /// Sanity cap: any header claiming a larger payload is treated as stream corruption.
    public static let maxPayloadLength: UInt32 = 16 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    /// Appends received bytes and returns any complete messages
    /// (each returned Data contains the 16-byte header followed by its payload).
    public func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []

        while buffer.count >= MessageHeader.size {
            guard let header = MessageHeader.from(data: buffer) else {
                // Unparseable header: drop buffer to resync
                buffer.removeAll(keepingCapacity: true)
                break
            }
            guard header.payloadLength <= MessageDeframer.maxPayloadLength else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            let total = MessageHeader.size + Int(header.payloadLength)
            guard buffer.count >= total else { break }

            messages.append(buffer.subdata(in: 0..<total))
            buffer.removeSubrange(0..<total)
        }
        return messages
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

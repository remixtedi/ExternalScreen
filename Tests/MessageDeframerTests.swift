import XCTest

final class MessageDeframerTests: XCTestCase {

    private func makeMessage(type: MessageType, payload: Data) -> Data {
        let header = MessageHeader(type: type, timestamp: 42, payloadLength: UInt32(payload.count))
        var data = header.toData()
        data.append(payload)
        return data
    }

    func testSingleCompleteMessage() {
        let deframer = MessageDeframer()
        let msg = makeMessage(type: .frameAck, payload: Data(repeating: 0x01, count: 12))
        let out = deframer.append(msg)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], msg)
    }

    func testMessageSplitAcrossChunks() {
        let deframer = MessageDeframer()
        let msg = makeMessage(type: .frameData, payload: Data(repeating: 0xCC, count: 1000))
        let chunk1 = msg.prefix(7)          // partial header
        let chunk2 = msg.dropFirst(7).prefix(500)  // rest of header + partial payload
        let chunk3 = msg.dropFirst(507)     // remainder

        XCTAssertEqual(deframer.append(Data(chunk1)).count, 0)
        XCTAssertEqual(deframer.append(Data(chunk2)).count, 0)
        let out = deframer.append(Data(chunk3))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], msg)
    }

    func testMultipleMessagesInOneChunk() {
        let deframer = MessageDeframer()
        let a = makeMessage(type: .frameAck, payload: Data(repeating: 0x0A, count: 12))
        let b = makeMessage(type: .cursorPosition, payload: Data(repeating: 0x0B, count: 9))
        var combined = a
        combined.append(b)
        let out = deframer.append(combined)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], a)
        XCTAssertEqual(out[1], b)
    }

    func testZeroLengthPayload() {
        let deframer = MessageDeframer()
        let msg = makeMessage(type: .disconnect, payload: Data())
        let out = deframer.append(msg)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].count, MessageHeader.size)
    }

    func testOversizedPayloadLengthResetsBuffer() {
        let deframer = MessageDeframer()
        // Craft header claiming a 100 MB payload (over the 16 MB sanity cap)
        let header = MessageHeader(type: .frameData, timestamp: 0, payloadLength: 100_000_000)
        let out = deframer.append(header.toData())
        XCTAssertEqual(out.count, 0)
        // After reset, a valid message must still parse
        let valid = makeMessage(type: .frameAck, payload: Data(repeating: 0x01, count: 12))
        XCTAssertEqual(deframer.append(valid).count, 1)
    }
}

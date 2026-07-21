import XCTest

final class ProtocolTests: XCTestCase {

    func testProtocolVersionIs2() {
        XCTAssertEqual(ExternalScreenConstants.protocolVersion, 2)
    }

    func testNetworkConstants() {
        XCTAssertEqual(ExternalScreenConstants.networkPort, 2346)
        XCTAssertEqual(ExternalScreenConstants.bonjourServiceType, "_extscreen._tcp")
    }

    func testNewMessageTypeRawValues() {
        XCTAssertEqual(MessageType.displayCapabilities.rawValue, 10)
        XCTAssertEqual(MessageType.cursorPosition.rawValue, 11)
        XCTAssertEqual(MessageType.cursorImage.rawValue, 12)
    }

    func testDisplayCapabilitiesRoundTrip() {
        let msg = DisplayCapabilitiesMessage(pixelWidth: 3456, pixelHeight: 2234, scale: 2.0)
        let decoded = DisplayCapabilitiesMessage.from(data: msg.toData())
        XCTAssertEqual(decoded?.pixelWidth, 3456)
        XCTAssertEqual(decoded?.pixelHeight, 2234)
        XCTAssertEqual(decoded?.scale, 2.0)
    }

    func testDisplayCapabilitiesRejectsShortData() {
        XCTAssertNil(DisplayCapabilitiesMessage.from(data: Data([0x01, 0x02])))
    }

    func testCursorPositionRoundTrip() {
        let msg = CursorPositionMessage(x: 0.25, y: 0.75, visible: true)
        let decoded = CursorPositionMessage.from(data: msg.toData())
        XCTAssertEqual(decoded?.x, 0.25)
        XCTAssertEqual(decoded?.y, 0.75)
        XCTAssertEqual(decoded?.visible, true)
    }

    func testCursorPositionInvisibleRoundTrip() {
        let msg = CursorPositionMessage(x: 0, y: 0, visible: false)
        XCTAssertEqual(CursorPositionMessage.from(data: msg.toData())?.visible, false)
    }

    func testCursorImageRoundTrip() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA, 0xBB])
        let msg = CursorImageMessage(hotspotX: 4.0, hotspotY: 2.0, pngData: png)
        let decoded = CursorImageMessage.from(data: msg.toData())
        XCTAssertEqual(decoded?.hotspotX, 4.0)
        XCTAssertEqual(decoded?.hotspotY, 2.0)
        XCTAssertEqual(decoded?.pngData, png)
    }

    func testCursorImageRejectsTruncatedPayload() {
        let png = Data(repeating: 0xAB, count: 100)
        let msg = CursorImageMessage(hotspotX: 0, hotspotY: 0, pngData: png)
        var data = msg.toData()
        data.removeLast(50)  // truncate PNG bytes
        XCTAssertNil(CursorImageMessage.from(data: data))
    }

    func testHandshakeRoundTrip() {
        let msg = HandshakeMessage(protocolVersion: 2, deviceName: "Giorgi's MacBook Pro")
        let decoded = HandshakeMessage.from(data: msg.toData())
        XCTAssertEqual(decoded?.protocolVersion, 2)
        XCTAssertEqual(decoded?.deviceName, "Giorgi's MacBook Pro")
    }

    func testHandshakeRoundTripEmptyDeviceName() {
        let msg = HandshakeMessage(protocolVersion: ExternalScreenConstants.protocolVersion, deviceName: "")
        let decoded = HandshakeMessage.from(data: msg.toData())
        XCTAssertEqual(decoded?.protocolVersion, ExternalScreenConstants.protocolVersion)
        XCTAssertEqual(decoded?.deviceName, "")
    }

    func testHandshakeRejectsShortData() {
        XCTAssertNil(HandshakeMessage.from(data: Data([0x01, 0x02])))
    }

    func testExistingMessagesStillRoundTrip() {
        let header = MessageHeader(type: .frameData, timestamp: 123456789, payloadLength: 42)
        let decodedHeader = MessageHeader.from(data: header.toData())
        XCTAssertEqual(decodedHeader?.type, .frameData)
        XCTAssertEqual(decodedHeader?.timestamp, 123456789)
        XCTAssertEqual(decodedHeader?.payloadLength, 42)

        let config = DisplayConfigMessage(width: 1440, height: 1005, refreshRate: 60.0)
        let decodedConfig = DisplayConfigMessage.from(data: config.toData())
        XCTAssertEqual(decodedConfig?.width, 1440)
        XCTAssertEqual(decodedConfig?.height, 1005)
    }
}

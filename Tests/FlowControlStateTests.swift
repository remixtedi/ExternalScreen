import XCTest

final class FlowControlStateTests: XCTestCase {

    func testCanSendInitially() {
        let flow = FlowControlState()
        XCTAssertTrue(flow.canSend(maxInFlight: 4))
    }

    func testBlocksWhenInFlightExceedsMax() {
        let flow = FlowControlState()
        for n in 1...6 { flow.recordSent(UInt32(n)) }
        // 6 sent, 0 acked -> 6 in flight > 4
        XCTAssertFalse(flow.canSend(maxInFlight: 4))
    }

    func testUnblocksAfterAck() {
        let flow = FlowControlState()
        for n in 1...6 { flow.recordSent(UInt32(n)) }
        flow.recordAck(5)  // 1 in flight
        XCTAssertTrue(flow.canSend(maxInFlight: 4))
    }

    func testAckDoesNotGoBackwards() {
        let flow = FlowControlState()
        for n in 1...6 { flow.recordSent(UInt32(n)) }
        flow.recordAck(6)
        flow.recordAck(2)  // stale ack, must be ignored
        XCTAssertTrue(flow.canSend(maxInFlight: 4))
    }

    func testDroppedCountAndReset() {
        let flow = FlowControlState()
        flow.recordDropped()
        flow.recordDropped()
        XCTAssertEqual(flow.droppedFrameCount, 2)
        flow.reset()
        XCTAssertEqual(flow.droppedFrameCount, 0)
        XCTAssertTrue(flow.canSend(maxInFlight: 4))
    }
}

import Foundation
import CoreGraphics
import AppKit

/// Handles touch events received from iPad and converts them to mouse events
final class TouchEventHandler {

    // MARK: - Properties

    private var displayID: CGDirectDisplayID = 0
    private var displayBounds: CGRect = .zero

    private var activeTouches: [UInt32: CGPoint] = [:]
    private var primaryTouchID: UInt32?

    private let eventSource: CGEventSource?

    // MARK: - Initialization

    init() {
        eventSource = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: - Configuration

    /// Sets the target display for touch events
    /// - Parameter displayID: The CGDirectDisplayID of the virtual display
    func setTargetDisplay(_ displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.displayBounds = CGDisplayBounds(displayID)
        print("TouchEventHandler: Target display set to \(displayID), bounds: \(displayBounds)")
    }

    // MARK: - Touch Event Processing

    /// Processes a touch began event
    /// - Parameter touch: The touch event message
    func handleTouchBegan(_ touch: TouchEventMessage) {
        let point = convertToScreenPoint(touch)
        activeTouches[touch.touchId] = point

        // First touch becomes primary (controls mouse)
        if primaryTouchID == nil {
            primaryTouchID = touch.touchId
            moveMouse(to: point)
            postMouseEvent(type: .leftMouseDown, at: point)
        }
    }

    /// Processes a touch moved event
    /// - Parameter touch: The touch event message
    func handleTouchMoved(_ touch: TouchEventMessage) {
        let point = convertToScreenPoint(touch)
        activeTouches[touch.touchId] = point

        if touch.touchId == primaryTouchID {
            postMouseEvent(type: .leftMouseDragged, at: point)
        }
    }

    /// Processes a touch ended event
    /// - Parameter touch: The touch event message
    func handleTouchEnded(_ touch: TouchEventMessage) {
        let point = activeTouches[touch.touchId] ?? convertToScreenPoint(touch)
        activeTouches.removeValue(forKey: touch.touchId)

        if touch.touchId == primaryTouchID {
            postMouseEvent(type: .leftMouseUp, at: point)
            primaryTouchID = nil

            // If there are other touches, promote one to primary
            if let nextTouch = activeTouches.first {
                primaryTouchID = nextTouch.key
                moveMouse(to: nextTouch.value)
                postMouseEvent(type: .leftMouseDown, at: nextTouch.value)
            }
        }
    }

    /// Processes a touch cancelled event
    /// - Parameter touch: The touch event message
    func handleTouchCancelled(_ touch: TouchEventMessage) {
        handleTouchEnded(touch)
    }

    /// Processes any touch event based on message type
    /// - Parameters:
    ///   - type: The message type
    ///   - touch: The touch event message
    func handleTouch(type: MessageType, touch: TouchEventMessage) {
        switch type {
        case .touchBegan:
            handleTouchBegan(touch)
        case .touchMoved:
            handleTouchMoved(touch)
        case .touchEnded:
            handleTouchEnded(touch)
        case .touchCancelled:
            handleTouchCancelled(touch)
        default:
            break
        }
    }

    // MARK: - Private Methods

    private func convertToScreenPoint(_ touch: TouchEventMessage) -> CGPoint {
        // Touch coordinates are normalized (0.0 - 1.0)
        // Convert to screen coordinates within the virtual display bounds
        let x = displayBounds.origin.x + CGFloat(touch.x) * displayBounds.width
        let y = displayBounds.origin.y + CGFloat(touch.y) * displayBounds.height
        return CGPoint(x: x, y: y)
    }

    private func moveMouse(to point: CGPoint) {
        let moveEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint) {
        let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll and Gesture Support

    /// Handles two-finger scroll gesture
    /// - Parameters:
    ///   - deltaX: Horizontal scroll amount
    ///   - deltaY: Vertical scroll amount
    func handleScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard let primaryPoint = activeTouches[primaryTouchID ?? 0] else { return }

        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY * 10),
            wheel2: Int32(deltaX * 10),
            wheel3: 0
        )
        scrollEvent?.location = primaryPoint
        scrollEvent?.post(tap: .cghidEventTap)
    }

    /// Simulates a right click (long press or two-finger tap)
    func handleRightClick(at point: CGPoint) {
        postMouseEvent(type: .rightMouseDown, at: point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postMouseEvent(type: .rightMouseUp, at: point)
        }
    }
}

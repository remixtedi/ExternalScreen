import UIKit

/// Delegate for touch events
protocol TouchCaptureViewDelegate: AnyObject {
    func touchCaptureView(_ view: TouchCaptureView, didBeginTouch touch: TouchEventMessage)
    func touchCaptureView(_ view: TouchCaptureView, didMoveTouch touch: TouchEventMessage)
    func touchCaptureView(_ view: TouchCaptureView, didEndTouch touch: TouchEventMessage)
    func touchCaptureView(_ view: TouchCaptureView, didCancelTouch touch: TouchEventMessage)
}

/// Full-screen view that captures all touch events
final class TouchCaptureView: UIView {

    // MARK: - Properties

    weak var delegate: TouchCaptureViewDelegate?

    /// Maps UITouch objects to their assigned IDs
    private var touchIDMap: [UITouch: UInt32] = [:]
    private var nextTouchID: UInt32 = 0

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let touchID = assignID(for: touch)
            let message = createTouchMessage(for: touch, touchID: touchID)
            delegate?.touchCaptureView(self, didBeginTouch: message)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let touchID = touchIDMap[touch] else { continue }
            let message = createTouchMessage(for: touch, touchID: touchID)
            delegate?.touchCaptureView(self, didMoveTouch: message)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let touchID = touchIDMap[touch] else { continue }
            let message = createTouchMessage(for: touch, touchID: touchID)
            delegate?.touchCaptureView(self, didEndTouch: message)
            releaseID(for: touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let touchID = touchIDMap[touch] else { continue }
            let message = createTouchMessage(for: touch, touchID: touchID)
            delegate?.touchCaptureView(self, didCancelTouch: message)
            releaseID(for: touch)
        }
    }

    // MARK: - Private Methods

    private func assignID(for touch: UITouch) -> UInt32 {
        let id = nextTouchID
        touchIDMap[touch] = id
        nextTouchID += 1
        return id
    }

    private func releaseID(for touch: UITouch) {
        touchIDMap.removeValue(forKey: touch)
    }

    private func createTouchMessage(for touch: UITouch, touchID: UInt32) -> TouchEventMessage {
        let location = touch.location(in: self)

        // Normalize coordinates to 0.0 - 1.0
        let normalizedX = Float(location.x / bounds.width)
        let normalizedY = Float(location.y / bounds.height)

        // Get force/pressure if available
        var pressure: Float = 1.0
        if traitCollection.forceTouchCapability == .available {
            pressure = Float(touch.force / touch.maximumPossibleForce)
        }

        return TouchEventMessage(
            touchId: touchID,
            x: normalizedX,
            y: normalizedY,
            pressure: pressure
        )
    }
}

import Cocoa

/// Streams the host cursor to a Mac receiver as separate messages so the
/// receiver can composite it locally — cursor latency becomes transport
/// latency instead of full video-pipeline latency.
final class CursorStreamer {

    private weak var transport: FrameTransport?
    private var displayID: CGDirectDisplayID = 0
    private var monitors: [Any] = []
    private var imageTimer: Timer?
    private var lastImagePNG: Data?
    private var wasOnDisplay = false

    func start(displayID: CGDirectDisplayID, transport: FrameTransport) {
        stop()
        self.displayID = displayID
        self.transport = transport

        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        // Global monitor covers other apps; local covers our own app being frontmost.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handleMouseEvent(event)
        }) {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        if let local = local {
            monitors.append(local)
        }

        // Cursor image changes are polled at 4 Hz (image is only sent when it changes).
        imageTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sendCursorImageIfChanged()
        }
        sendCursorImageIfChanged()
        // Push an initial position so the receiver shows the cursor immediately if it's already there
        sendCurrentPosition()

        print("CursorStreamer: started for display \(displayID)")
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        imageTimer?.invalidate()
        imageTimer = nil
        lastImagePNG = nil
        wasOnDisplay = false
    }

    // MARK: - Position

    private func handleMouseEvent(_ event: NSEvent) {
        // CGEvent location is in global top-left-origin coordinates, matching CGDisplayBounds.
        guard let location = event.cgEvent?.location else { return }
        send(location: location)
    }

    private func sendCurrentPosition() {
        guard let location = CGEvent(source: nil)?.location else { return }
        send(location: location)
    }

    private func send(location: CGPoint) {
        guard let transport = transport else { return }
        let bounds = CGDisplayBounds(displayID)
        let inside = bounds.contains(location)

        if inside {
            let x = Float((location.x - bounds.origin.x) / bounds.width)
            let y = Float((location.y - bounds.origin.y) / bounds.height)
            transport.sendMessage(type: .cursorPosition,
                                  payload: CursorPositionMessage(x: x, y: y, visible: true).toData())
            wasOnDisplay = true
        } else if wasOnDisplay {
            // Send a single "hide" when the cursor leaves the virtual display
            transport.sendMessage(type: .cursorPosition,
                                  payload: CursorPositionMessage(x: 0, y: 0, visible: false).toData())
            wasOnDisplay = false
        }
    }

    // MARK: - Image

    private func sendCursorImageIfChanged() {
        guard let transport = transport else { return }
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let image = cursor.image

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        guard png != lastImagePNG else { return }
        lastImagePNG = png

        // Hotspot is in image points; convert to image pixels for the receiver.
        let pixelScale = CGFloat(rep.pixelsWide) / max(image.size.width, 1)
        let hotspot = cursor.hotSpot
        let msg = CursorImageMessage(
            hotspotX: Float(hotspot.x * pixelScale),
            hotspotY: Float(hotspot.y * pixelScale),
            pngData: png
        )
        transport.sendMessage(type: .cursorImage, payload: msg.toData())
        print("CursorStreamer: sent cursor image (\(png.count) bytes, hotspot \(hotspot))")
    }
}

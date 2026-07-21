import Cocoa

/// Streams the host cursor to a Mac receiver as separate messages so the
/// receiver can composite it locally — cursor latency becomes transport
/// latency instead of full video-pipeline latency.
final class CursorStreamer {

    private weak var transport: FrameTransport?
    private var displayID: CGDirectDisplayID = 0
    private var receiverScale: CGFloat = 2.0

    // NSEvent global/local monitors and a run-loop Timer both stall while the host's main
    // thread is in tracking-event mode (window drags, menu tracking) -- exactly when the
    // user is moving the mouse the most. Poll from a dedicated background queue instead so
    // cursor updates keep flowing regardless of what the main run loop is doing.
    private let pollQueue = DispatchQueue(label: "com.externalscreen.cursor.poll", qos: .userInteractive)
    private var positionTimer: DispatchSourceTimer?
    private var imageTimer: DispatchSourceTimer?

    private var lastImagePNG: Data?
    private var wasOnDisplay = false
    /// Touched only on `pollQueue` (single-writer/reader from the position timer's
    /// handler) -- no locking needed.
    private var lastLocation: CGPoint?

    func start(displayID: CGDirectDisplayID, transport: FrameTransport, receiverScale: CGFloat) {
        stop()
        self.displayID = displayID
        self.transport = transport
        self.receiverScale = (receiverScale.isFinite && receiverScale > 0) ? receiverScale : 2.0

        // Position: 120 Hz poll of the (thread-safe) CGEvent cursor location.
        let positionTimer = DispatchSource.makeTimerSource(queue: pollQueue)
        positionTimer.schedule(deadline: .now(), repeating: .milliseconds(8))
        positionTimer.setEventHandler { [weak self] in
            self?.pollPosition()
        }
        positionTimer.resume()
        self.positionTimer = positionTimer

        // Image: 4 Hz poll (image is only sent when it changes). NSCursor/NSImage are
        // AppKit calls that are main-thread-preferred, so hop to main for the actual work;
        // the image freezing during a drag is acceptable since the cursor shape rarely
        // changes mid-drag.
        let imageTimer = DispatchSource.makeTimerSource(queue: pollQueue)
        imageTimer.schedule(deadline: .now(), repeating: .milliseconds(250))
        imageTimer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.sendCursorImageIfChanged()
            }
        }
        imageTimer.resume()
        self.imageTimer = imageTimer

        print("CursorStreamer: started for display \(displayID)")
    }

    func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        imageTimer?.cancel()
        imageTimer = nil
        lastImagePNG = nil
        wasOnDisplay = false
        lastLocation = nil
    }

    // MARK: - Position

    /// Runs on `pollQueue` at 120 Hz.
    private func pollPosition() {
        // CGEvent location is in global top-left-origin coordinates, matching
        // CGDisplayBounds, and (unlike NSEvent) is a thread-safe CG call.
        guard let location = CGEvent(source: nil)?.location else { return }
        guard location != lastLocation else { return }
        lastLocation = location
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

    /// Runs on the main queue (hopped to from the `pollQueue` image timer).
    private func sendCursorImageIfChanged() {
        guard let transport = transport else { return }
        let cursor = NSCursor.currentSystem ?? NSCursor.current
        let image = cursor.image

        // Pick the bitmap rep whose pixel width matches the receiver's scale, not simply
        // the largest available rep: system cursor images can carry very large
        // accessibility/cursor-zoom reps alongside the normal 1x/2x/3x set, and picking
        // "largest" grabs those oversized reps, streaming a giant image that the receiver
        // then draws 1:1 in drawable pixels. Target pixel width = point size * receiver scale.
        let targetWidth = image.size.width * receiverScale
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep: NSBitmapImageRep?
        if let closest = bitmapReps.min(by: { lhs, rhs in
            let lhsDelta = abs(CGFloat(lhs.pixelsWide) - targetWidth)
            let rhsDelta = abs(CGFloat(rhs.pixelsWide) - targetWidth)
            if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
            // Tie: prefer the rep that meets or exceeds the target size.
            return CGFloat(lhs.pixelsWide) >= targetWidth && CGFloat(rhs.pixelsWide) < targetWidth
        }) {
            rep = closest
        } else if let tiff = image.tiffRepresentation {
            rep = NSBitmapImageRep(data: tiff)
        } else {
            rep = nil
        }

        guard let rep = rep,
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

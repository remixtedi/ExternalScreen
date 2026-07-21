import Cocoa
import MetalKit
import CoreMedia
import IOKit.pwr_mgt

/// Runs Receiver mode: fullscreen black window on this Mac's screen,
/// listens for a host over TCP/Bonjour, decodes and renders its stream.
final class ReceiverSessionController: NSObject {

    var onExit: (() -> Void)?

    private var window: NSWindow?
    private var metalView: MTKView!
    private var renderer: MetalRenderer?
    private var decoder: H264Decoder!
    private var transport: NetworkReceiverTransport!
    private var waitingLabel: NSTextField!
    private var sleepAssertionID: IOPMAssertionID = 0
    private var keyMonitor: Any?
    private var isStopped = false
    /// Set once the host's handshake has been validated (protocol version match) and our
    /// reply sent. Guards against acting on frameData/cursor messages that might arrive
    /// before the handshake completes.
    private var didHandshake = false

    func start() throws {
        let screen = NSScreen.main ?? NSScreen.screens[0]

        // Fullscreen borderless window
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        self.window = window

        metalView = MTKView(frame: window.contentView!.bounds)
        metalView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(metalView)

        waitingLabel = NSTextField(labelWithString: "External Screen\nWaiting for host Mac…\n\nPress Esc to exit")
        waitingLabel.alignment = .center
        waitingLabel.textColor = .white
        waitingLabel.font = .systemFont(ofSize: 24, weight: .medium)
        waitingLabel.maximumNumberOfLines = 0
        waitingLabel.sizeToFit()
        waitingLabel.frame.origin = CGPoint(
            x: (window.contentView!.bounds.width - waitingLabel.frame.width) / 2,
            y: (window.contentView!.bounds.height - waitingLabel.frame.height) / 2
        )
        waitingLabel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        window.contentView!.addSubview(waitingLabel)

        renderer = MetalRenderer(metalView: metalView)
        decoder = H264Decoder()
        decoder.delegate = self
        decoder.setFrameRate(Int(ExternalScreenConstants.defaultRefreshRate))

        let name = Host.current().localizedName ?? "Mac"
        transport = NetworkReceiverTransport(serviceName: name)
        transport.transportDelegate = self
        try transport.start()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()

        // Esc exits receiver mode
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                self?.stop()
                return nil
            }
            return event
        }

        preventSleep()
        print("ReceiverSessionController: started, advertising as \(name)")
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

        transport?.stop()
        decoder?.stop()
        renderer?.clear()
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        allowSleep()
        NSCursor.unhide()
        window?.orderOut(nil)
        window = nil
        onExit?()
    }

    // MARK: - Sleep prevention

    private func preventSleep() {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "External Screen receiver active" as CFString,
            &sleepAssertionID
        )
    }

    private func allowSleep() {
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }

    // MARK: - Capabilities

    private func sendCapabilities() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let pixelWidth = UInt32(screen.frame.width * scale)
        let pixelHeight = UInt32(screen.frame.height * scale)
        let caps = DisplayCapabilitiesMessage(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: Float(scale))
        print("ReceiverSessionController: sending capabilities \(pixelWidth)x\(pixelHeight) @\(scale)x")
        transport.sendMessage(type: .displayCapabilities, payload: caps.toData())
    }
}

/// Borderless windows refuse key status by default; we need Esc handling.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - FrameTransportDelegate

extension ReceiverSessionController: FrameTransportDelegate {

    func transportDidConnect(_ transport: FrameTransport, endpointName: String) {
        print("ReceiverSessionController: host connected, awaiting handshake")
        // Do NOT send capabilities or hide the waiting label yet — that now happens only
        // after a successful `.handshake` exchange (see `transport(_:didReceive:)`), so a
        // version-mismatched host never gets treated as a valid session.
        didHandshake = false
    }

    func transportDidDisconnect(_ transport: FrameTransport) {
        print("ReceiverSessionController: host disconnected")
        didHandshake = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.waitingLabel.isHidden = false
            self.decoder.reset()
            self.renderer?.clear()
            self.renderer?.clearCursor()
        }
    }

    func transport(_ transport: FrameTransport, didReceive data: Data) {
        guard let header = MessageHeader.from(data: data) else { return }
        let payload = data.subdata(in: MessageHeader.size..<data.count)

        switch header.type {
        case .handshake:
            guard let handshake = HandshakeMessage.from(data: payload) else { return }
            guard handshake.protocolVersion == ExternalScreenConstants.protocolVersion else {
                print("ReceiverSessionController: handshake version mismatch (host=\(handshake.protocolVersion), expected=\(ExternalScreenConstants.protocolVersion)), disconnecting")
                transport.disconnect()
                return
            }
            print("ReceiverSessionController: handshake ok with host '\(handshake.deviceName)' (v\(handshake.protocolVersion))")
            let reply = HandshakeMessage(
                protocolVersion: ExternalScreenConstants.protocolVersion,
                deviceName: Host.current().localizedName ?? "Mac"
            )
            transport.sendMessage(type: .handshake, payload: reply.toData())
            didHandshake = true
            // `didReceive` runs on the transport's background queue (unlike
            // `transportDidConnect`, which NetworkReceiverTransport dispatches to main) —
            // hop to main before touching the waiting label or NSScreen in sendCapabilities().
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.waitingLabel.isHidden = true
                self.sendCapabilities()
            }

        case .displayConfig:
            if let config = DisplayConfigMessage.from(data: payload) {
                print("ReceiverSessionController: display config \(config.width)x\(config.height) @\(config.refreshRate)")
                decoder.reset()
                decoder.setFrameRate(Int(config.refreshRate))
            }

        case .frameData:
            guard didHandshake else { return }
            guard payload.count >= FrameDataHeader.size,
                  let frameHeader = FrameDataHeader.from(data: payload) else { return }
            let frameData = payload.subdata(in: FrameDataHeader.size..<payload.count)
            decoder.decode(data: frameData, presentationTime: frameHeader.presentationTime)
            let ack = FrameAckMessage(
                frameNumber: frameHeader.frameNumber,
                receivedTime: UInt64(Date().timeIntervalSince1970 * 1_000_000)
            )
            transport.sendMessage(type: .frameAck, payload: ack.toData())

        case .cursorPosition:
            guard didHandshake else { return }
            if let pos = CursorPositionMessage.from(data: payload) {
                renderer?.setCursorPosition(x: pos.x, y: pos.y, visible: pos.visible)
            }

        case .cursorImage:
            guard didHandshake else { return }
            if let img = CursorImageMessage.from(data: payload) {
                renderer?.setCursorImage(pngData: img.pngData, hotspotX: img.hotspotX, hotspotY: img.hotspotY)
            }

        case .disconnect:
            transport.disconnect()

        default:
            break
        }
    }
}

// MARK: - H264DecoderDelegate

extension ReceiverSessionController: H264DecoderDelegate {
    func h264Decoder(_ decoder: H264Decoder, didDecode pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        renderer?.display(pixelBuffer: pixelBuffer)
    }

    func h264Decoder(_ decoder: H264Decoder, didFailWithError error: Error) {
        print("ReceiverSessionController: decoder error: \(error)")
    }
}

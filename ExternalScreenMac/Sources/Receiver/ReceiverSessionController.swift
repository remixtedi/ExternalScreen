import Cocoa
import MetalKit
import CoreMedia
import IOKit.pwr_mgt

/// Runs Receiver mode as a long-lived, two-state service:
///
/// - **standby**: the transport listens and advertises via Bonjour, but there is no
///   window, decoder, or renderer. This is the resting state whenever "Allow Using as
///   Display" is enabled and no host is currently streaming to this Mac.
/// - **active**: a fullscreen black window, `MetalRenderer`, and `H264Decoder` are live.
///   Entered automatically once a host completes the handshake; exited automatically on
///   host disconnect or Esc, returning to standby — the transport keeps listening for the
///   next host. Only `stop()` tears down the listener.
final class ReceiverSessionController: NSObject {

    enum State {
        case standby
        case active
    }

    /// Fires once, when the service is fully stopped (transport listener torn down).
    /// Does NOT fire on standby <-> active transitions.
    var onExit: (() -> Void)?

    /// Set by AppDelegate. Return `true` when this Mac's own host pipeline is currently
    /// running, so an incoming handshake should be rejected — this Mac can't be an active
    /// receiver and an active host at the same time. Queried on the main thread.
    var isHostBusy: (() -> Bool)?

    private(set) var state: State = .standby

    private var window: NSWindow?
    private var metalView: MTKView?

    /// Guards all reads/writes of `renderer`, `decoder`, and `didHandshake`.
    /// `transport(_:didReceive:)` runs on the transport's background queue and reads
    /// these directly (frame handling intentionally never hops to main — latency
    /// priority), while `activate()`/`deactivate()`/the handshake handler mutate them on
    /// the main thread as the session cycles between standby and active. Never held
    /// across window/UI operations or calls into `transport`.
    private let sessionLock = NSLock()
    private var renderer: MetalRenderer?
    private var decoder: H264Decoder?
    /// Set once the host's handshake has been validated (protocol version match, and this
    /// Mac isn't itself busy hosting) and our reply sent. Guards against acting on
    /// displayConfig/frameData/cursor messages that might arrive before the handshake
    /// completes. Only ever `true` while `state == .active`.
    private var didHandshake = false

    private var transport: NetworkReceiverTransport!
    private var sleepAssertionID: IOPMAssertionID = 0
    private var keyMonitor: Any?
    private var isStopped = false

    /// Snapshots `renderer`/`decoder`/`didHandshake` under `sessionLock`. Callers on the
    /// transport's background queue use this instead of touching the properties directly,
    /// so a concurrent `activate()`/`deactivate()` on the main thread can't race them.
    /// ARC keeps the snapshotted `decoder`/`renderer` alive even if `deactivate()` nils
    /// out `self.decoder`/`self.renderer` immediately afterward.
    private func snapshotSession() -> (didHandshake: Bool, decoder: H264Decoder?, renderer: MetalRenderer?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return (didHandshake, decoder, renderer)
    }

    /// Enters standby: starts the transport listener + Bonjour advertising only. No
    /// window, decoder, or renderer is created until a host completes the handshake.
    func start() throws {
        let name = Host.current().localizedName ?? "Mac"
        transport = NetworkReceiverTransport(serviceName: name)
        transport.transportDelegate = self
        try transport.start()
        state = .standby
        print("ReceiverSessionController: standby, advertising as \(name)")
    }

    /// Fully stops the service: tears down the active session (if any) and stops the
    /// transport listener. Call on app quit or when "Allow Using as Display" is turned off.
    func stop() {
        guard !isStopped else { return }
        isStopped = true

        if state == .active {
            deactivate()
        }
        transport?.stop()
        onExit?()
    }

    // MARK: - State transitions

    /// standby -> active: builds the fullscreen window/renderer/decoder pipeline, hides
    /// the cursor, and prevents display sleep. Must run on the main thread.
    private func activate() {
        guard state == .standby else { return }
        state = .active

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

        let metalView = MTKView(frame: window.contentView!.bounds)
        metalView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(metalView)
        self.metalView = metalView

        let renderer = MetalRenderer(metalView: metalView)
        let decoder = H264Decoder()
        decoder.delegate = self
        decoder.setFrameRate(Int(ExternalScreenConstants.defaultRefreshRate))

        sessionLock.lock()
        self.renderer = renderer
        self.decoder = decoder
        sessionLock.unlock()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()

        // Esc exits back to standby — does not stop the listener.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                self?.deactivate()
                self?.transport.disconnect()
                return nil
            }
            return event
        }

        preventSleep()
        print("ReceiverSessionController: activated (host connected)")
    }

    /// active -> standby: tears down window/renderer/decoder, unhides the cursor, and
    /// releases the sleep assertion. Does NOT touch the transport listener, which keeps
    /// listening for the next host. Must run on the main thread.
    private func deactivate() {
        guard state == .active else { return }
        state = .standby

        // Snapshot-and-nil under the lock, then operate on the snapshots outside it —
        // `decoder.stop()` can block briefly draining in-flight frames, and we must never
        // hold `sessionLock` across that.
        sessionLock.lock()
        didHandshake = false
        let oldDecoder = decoder
        let oldRenderer = renderer
        decoder = nil
        renderer = nil
        sessionLock.unlock()

        oldDecoder?.stop()
        oldRenderer?.clear()
        oldRenderer?.clearCursor()
        metalView = nil
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        allowSleep()
        NSCursor.unhide()
        window?.orderOut(nil)
        window = nil

        print("ReceiverSessionController: deactivated, back to standby")
    }

    /// A new host's handshake succeeded while already `.active` — the previous host's
    /// connection was superseded (e.g. its disconnect notification hadn't arrived yet
    /// when the new one connected). Keeps the existing fullscreen window (no flicker),
    /// but replaces the decoder and clears the renderer so no stale frames/cursor from
    /// the old host linger; `sendCapabilities()` then re-advertises to the new host as
    /// usual. Must run on the main thread.
    private func resetForNewHost() {
        let newDecoder = H264Decoder()
        newDecoder.delegate = self
        newDecoder.setFrameRate(Int(ExternalScreenConstants.defaultRefreshRate))

        sessionLock.lock()
        let oldDecoder = decoder
        let currentRenderer = renderer
        decoder = newDecoder
        sessionLock.unlock()

        oldDecoder?.stop()
        currentRenderer?.clear()
        currentRenderer?.clearCursor()
        // The new host sends its own displayConfig; don't inherit the old host's rotation.
        currentRenderer?.setRotation(0)

        print("ReceiverSessionController: new host superseded active session, reset decoder/renderer")
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
        sessionLock.lock()
        didHandshake = false
        sessionLock.unlock()
    }

    func transportDidDisconnect(_ transport: FrameTransport) {
        print("ReceiverSessionController: host disconnected")
        // `deactivate()` clears `didHandshake` itself (under the lock).
        deactivate()
    }

    func transport(_ transport: FrameTransport, didReceive data: Data) {
        guard let header = MessageHeader.from(data: data) else { return }
        let payload = data.subdata(in: MessageHeader.size..<data.count)

        switch header.type {
        case .handshake:
            guard let handshake = HandshakeMessage.from(data: payload) else { return }
            // `didReceive` runs on the transport's background queue; `isHostBusy` reads
            // AppDelegate's `isRunning`, and on success `activate()` touches NSScreen/AppKit
            // — both require the main thread.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if self.isHostBusy?() == true {
                    print("ReceiverSessionController: rejecting handshake — this Mac's own host pipeline is running")
                    self.transport.disconnect()
                    return
                }

                guard handshake.protocolVersion == ExternalScreenConstants.protocolVersion else {
                    print("ReceiverSessionController: handshake version mismatch (host=\(handshake.protocolVersion), expected=\(ExternalScreenConstants.protocolVersion)), disconnecting")
                    self.transport.disconnect()
                    return
                }

                print("ReceiverSessionController: handshake ok with host '\(handshake.deviceName)' (v\(handshake.protocolVersion))")
                let reply = HandshakeMessage(
                    protocolVersion: ExternalScreenConstants.protocolVersion,
                    deviceName: Host.current().localizedName ?? "Mac"
                )
                self.transport.sendMessage(type: .handshake, payload: reply.toData())

                self.sessionLock.lock()
                self.didHandshake = true
                self.sessionLock.unlock()

                if self.state == .active {
                    // A different host's connection superseded the one we were
                    // streaming to — reset decoder/renderer for the new host instead of
                    // silently no-op'ing (activate() is a no-op once already active).
                    self.resetForNewHost()
                } else {
                    self.activate()
                }
                self.sendCapabilities()
            }

        case .displayConfig:
            let session = snapshotSession()
            guard session.didHandshake else { return }
            if let config = DisplayConfigMessage.from(data: payload) {
                print("ReceiverSessionController: display config \(config.width)x\(config.height) @\(config.refreshRate) rotation=\(config.rotation)°")
                session.decoder?.reset()
                session.decoder?.setFrameRate(Int(config.refreshRate))
                session.renderer?.setRotation(Int(config.rotation))
            }

        case .frameData:
            let session = snapshotSession()
            guard session.didHandshake else { return }
            guard payload.count >= FrameDataHeader.size,
                  let frameHeader = FrameDataHeader.from(data: payload) else { return }
            let frameData = payload.subdata(in: FrameDataHeader.size..<payload.count)
            session.decoder?.decode(data: frameData, presentationTime: frameHeader.presentationTime)
            let ack = FrameAckMessage(
                frameNumber: frameHeader.frameNumber,
                receivedTime: UInt64(Date().timeIntervalSince1970 * 1_000_000)
            )
            transport.sendMessage(type: .frameAck, payload: ack.toData())

        case .cursorPosition:
            let session = snapshotSession()
            guard session.didHandshake else { return }
            if let pos = CursorPositionMessage.from(data: payload) {
                session.renderer?.setCursorPosition(x: pos.x, y: pos.y, visible: pos.visible)
            }

        case .cursorImage:
            let session = snapshotSession()
            guard session.didHandshake else { return }
            if let img = CursorImageMessage.from(data: payload) {
                session.renderer?.setCursorImage(pngData: img.pngData, hotspotX: img.hotspotX, hotspotY: img.hotspotY)
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
        // Fires on H264Decoder's own callback queue, not main — same cross-queue hazard
        // as `transport(_:didReceive:)`, so go through the lock rather than reading
        // `renderer` directly.
        sessionLock.lock()
        let currentRenderer = renderer
        sessionLock.unlock()
        currentRenderer?.display(pixelBuffer: pixelBuffer)
    }

    func h264Decoder(_ decoder: H264Decoder, didFailWithError error: Error) {
        print("ReceiverSessionController: decoder error: \(error)")
    }
}

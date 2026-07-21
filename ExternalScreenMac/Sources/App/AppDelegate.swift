import Cocoa
import ScreenCaptureKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var mainWindowController: MainWindowController?

    // Core components
    private var virtualDisplayManager: VirtualDisplayManager!
    private var screenCaptureManager: ScreenCaptureManager!
    private var h264Encoder: H264Encoder!
    private var usbDeviceManager: USBDeviceManager!
    private var touchEventHandler: TouchEventHandler!

    // Mac-to-Mac networking
    private var networkTransport: NetworkHostTransport?
    private var receiverBrowser: ReceiverBrowser!
    private var discoveredReceivers: [DiscoveredReceiver] = []
    private var receiversMenu: NSMenu!
    private var receiverSession: ReceiverSessionController?

    /// The transport currently carrying the stream (PeerTalk for iPad by default).
    private var activeTransport: FrameTransport {
        networkTransport ?? usbDeviceManager
    }

    private enum TargetKind { case iPad, macReceiver }
    private var targetKind: TargetKind = .iPad
    /// Guards against re-entrant `connectToReceiver` calls (e.g. a double-click on the menu item).
    private var isConnectingToReceiver = false
    /// Guards against re-entrant `enterReceiverMode` calls during the awaited host teardown,
    /// when `receiverSession` is still nil but `isRunning` has already flipped false.
    private var isEnteringReceiverMode = false

    // State
    private var isRunning = false
    private var frameNumber: UInt32 = 0
    private var didDropFrames = false  // Track if we dropped frames and need a keyframe
    private(set) var currentPreset: DisplayPreset = ExternalScreenConstants.defaultPreset
    private var presetMenuItems: [NSMenuItem] = []
    private var isPortrait: Bool = false
    private var orientationDebounceTask: Task<Void, Never>?

    /// Effective width accounting for orientation
    private var effectiveWidth: Int {
        isPortrait ? currentPreset.height : currentPreset.width
    }

    /// Effective height accounting for orientation
    private var effectiveHeight: Int {
        isPortrait ? currentPreset.width : currentPreset.height
    }

    // Debug logging
    private func log(_ message: String) {
        let logPath = "/tmp/ExternalScreen_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(logMessage.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: logMessage.data(using: .utf8))
        }
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app is a regular app with dock icon
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        setupStatusBarItem()
        initializeComponents()
        showMainWindow()

        // Request screen recording permission
        Task {
            await requestScreenCapturePermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPipeline()
        receiverSession?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep running in menu bar
    }

    // MARK: - Setup

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Try SF Symbol first, fall back to text
            if let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "External Screen") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "ExtMon"
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start", action: #selector(startPipeline), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopPipeline), keyEquivalent: "x"))
        menu.addItem(NSMenuItem.separator())

        // Resolution presets submenu
        let presetMenu = NSMenu()
        presetMenuItems.removeAll()
        for (index, preset) in DisplayPreset.allCases.enumerated() {
            let item = NSMenuItem(
                title: "\(preset.rawValue) (\(preset.description))",
                action: #selector(selectPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index  // Use tag to identify preset
            item.state = (preset == currentPreset) ? .on : .off
            presetMenuItems.append(item)
            presetMenu.addItem(item)
        }

        let presetMenuItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        presetMenuItem.submenu = presetMenu
        menu.addItem(presetMenuItem)

        receiversMenu = NSMenu()
        let receiversMenuItem = NSMenuItem(title: "Connect to Mac", action: nil, keyEquivalent: "")
        receiversMenuItem.submenu = receiversMenu
        menu.addItem(receiversMenuItem)
        rebuildReceiversMenu()

        menu.addItem(NSMenuItem(title: "Use This Mac as Receiver", action: #selector(enterReceiverMode), keyEquivalent: "r"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "w"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard targetKind == .iPad else {
            log("Preset change ignored: Mac receiver uses native resolution")
            return
        }

        let allPresets = DisplayPreset.allCases
        guard sender.tag >= 0 && sender.tag < allPresets.count else {
            log("selectPreset: Invalid tag \(sender.tag)")
            return
        }

        let preset = allPresets[sender.tag]
        log("selectPreset: Selected tag \(sender.tag) -> \(preset.rawValue)")

        // Update checkmark
        for (index, item) in presetMenuItems.enumerated() {
            item.state = (index == sender.tag) ? .on : .off
        }

        currentPreset = preset
        log("selectPreset: Changed to \(preset.rawValue) (\(preset.description))")
        print("ExternalScreen: Preset changed to \(preset.rawValue) (\(preset.description))")

        // If running, restart the pipeline with new resolution
        if isRunning {
            log("selectPreset: Restarting pipeline with new resolution...")
            restartWithNewPreset()
        } else {
            // Reinitialize components with new preset so they're ready when we start
            log("selectPreset: Reinitializing components with new preset...")
            reinitializeComponentsWithCurrentPreset()
        }
    }

    // MARK: - Receiver Discovery

    private func rebuildReceiversMenu() {
        receiversMenu.removeAllItems()
        if discoveredReceivers.isEmpty {
            let empty = NSMenuItem(title: "No Macs found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            receiversMenu.addItem(empty)
            return
        }
        for (index, receiver) in discoveredReceivers.enumerated() {
            let item = NSMenuItem(title: receiver.name, action: #selector(connectToReceiver(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            receiversMenu.addItem(item)
        }
    }

    @objc private func connectToReceiver(_ sender: NSMenuItem) {
        guard sender.tag >= 0 && sender.tag < discoveredReceivers.count else { return }
        guard !isConnectingToReceiver else {
            log("connectToReceiver: Already connecting, ignoring duplicate request")
            return
        }
        isConnectingToReceiver = true

        let receiver = discoveredReceivers[sender.tag]
        log("Connecting to Mac receiver: \(receiver.name)")

        // Tear down any current network session
        networkTransport?.disconnect()

        func beginConnection() {
            targetKind = .macReceiver
            let transport = NetworkHostTransport(endpoint: receiver.endpoint, name: receiver.name)
            transport.transportDelegate = self
            networkTransport = transport

            if !isRunning {
                startPipeline()
            }
            transport.start()
            isConnectingToReceiver = false
        }

        // An iPad session must not run concurrently with a Mac receiver session.
        guard usbDeviceManager.isConnected else {
            beginConnection()
            return
        }

        log("connectToReceiver: Tearing down live iPad session before connecting to Mac receiver")
        if #available(macOS 14.0, *) {
            Task {
                await screenCaptureManager.stopCapture()
                await MainActor.run {
                    h264Encoder.stop()
                    usbDeviceManager.disconnect()
                    beginConnection()
                }
            }
        } else {
            h264Encoder.stop()
            usbDeviceManager.disconnect()
            beginConnection()
        }
    }

    @objc private func enterReceiverMode() {
        guard receiverSession == nil, !isEnteringReceiverMode else { return }
        isEnteringReceiverMode = true
        log("Entering receiver mode")

        // Host and receiver roles are mutually exclusive. If the host pipeline is
        // running, await its full teardown (including the virtual display, which this
        // Mac must not keep attached while acting as a screen) before starting the
        // receiver session, so the two pipelines never briefly co-exist.
        guard isRunning else {
            startReceiverSession()
            return
        }

        isRunning = false
        if #available(macOS 14.0, *) {
            Task {
                await stopPipelineTeardown(stopVirtualDisplay: true)
                await MainActor.run {
                    self.startReceiverSession()
                }
            }
        } else {
            h264Encoder.stop()
            usbDeviceManager.disconnect()
            receiverBrowser.stop()
            networkTransport?.disconnect()
            networkTransport = nil
            targetKind = .iPad
            isConnectingToReceiver = false
            virtualDisplayManager.stop()
            updateStatusIcon(connected: false)
            updateStatus("Stopped", state: .idle)
            startReceiverSession()
        }
    }

    private func startReceiverSession() {
        let session = ReceiverSessionController()
        session.onExit = { [weak self] in
            self?.receiverSession = nil
            self?.log("Exited receiver mode")
        }
        do {
            try session.start()
            receiverSession = session
        } catch {
            log("Failed to start receiver mode: \(error)")
            showAlert(title: "Receiver Mode Failed",
                      message: "Could not listen on port \(ExternalScreenConstants.networkPort): \(error.localizedDescription)")
        }
        isEnteringReceiverMode = false
    }

    private func reinitializeComponentsWithCurrentPreset() {
        // Reinitialize managers with effective dimensions (accounting for orientation)
        let w = effectiveWidth
        let h = effectiveHeight
        virtualDisplayManager = VirtualDisplayManager(width: w, height: h)
        virtualDisplayManager.delegate = self

        if #available(macOS 14.0, *) {
            screenCaptureManager = ScreenCaptureManager(width: w, height: h, frameRate: Int(ExternalScreenConstants.defaultRefreshRate))
            screenCaptureManager.delegate = self
        }

        h264Encoder = H264Encoder(width: w, height: h, frameRate: Int(ExternalScreenConstants.defaultRefreshRate), bitrate: currentPreset.recommendedBitrate, keyframeInterval: ExternalScreenConstants.keyframeInterval)
        h264Encoder.delegate = self

        print("ExternalScreen Mac: Components reinitialized with \(w)x\(h) (\(currentPreset.rawValue))")
    }

    private func restartWithNewPreset() {
        // Stop current capture and encoding
        if #available(macOS 14.0, *) {
            Task {
                await screenCaptureManager.stopCapture()
                h264Encoder.stop()

                // Update virtual display resolution (keeps same display ID and USB connection)
                let w = self.effectiveWidth
                let h = self.effectiveHeight
                let updated = virtualDisplayManager.updateResolution(width: w, height: h)
                log("restartWithNewPreset: updateResolution(\(w)x\(h)) -> \(updated)")

                // Recreate encoder and capture manager with effective dimensions
                h264Encoder = H264Encoder(width: w, height: h, frameRate: Int(ExternalScreenConstants.defaultRefreshRate), bitrate: currentPreset.recommendedBitrate, keyframeInterval: ExternalScreenConstants.keyframeInterval)
                h264Encoder.delegate = self

                screenCaptureManager = ScreenCaptureManager(width: w, height: h, frameRate: Int(ExternalScreenConstants.defaultRefreshRate))
                screenCaptureManager.delegate = self

                // Reset frame counter for clean restart
                frameNumber = 0
                didDropFrames = false
                activeTransport.resetFlowControl()

                // Restart if iPad is connected
                if activeTransport.isConnected {
                    // Send updated display config with effective dimensions
                    let config = DisplayConfigMessage(
                        width: UInt32(w),
                        height: UInt32(h),
                        refreshRate: Float(ExternalScreenConstants.defaultRefreshRate)
                    )
                    activeTransport.sendMessage(type: .displayConfig, payload: config.toData())

                    // Wait for ScreenCaptureKit to detect the updated display
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    // Restart capture and encoding
                    startCaptureAndEncoding()
                }

                log("restartWithNewPreset: Complete - now using \(w)x\(h)")
            }
        }
    }

    private func initializeComponents() {
        // Initialize managers with current preset
        virtualDisplayManager = VirtualDisplayManager(preset: currentPreset)
        virtualDisplayManager.delegate = self

        if #available(macOS 14.0, *) {
            screenCaptureManager = ScreenCaptureManager(preset: currentPreset)
            screenCaptureManager.delegate = self
        }

        h264Encoder = H264Encoder(preset: currentPreset)
        h264Encoder.delegate = self

        usbDeviceManager = USBDeviceManager()
        usbDeviceManager.transportDelegate = self

        touchEventHandler = TouchEventHandler()

        print("ExternalScreen Mac: Components initialized with preset \(currentPreset.rawValue) (\(currentPreset.description))")

        receiverBrowser = ReceiverBrowser()
        receiverBrowser.onResultsChanged = { [weak self] receivers in
            self?.discoveredReceivers = receivers
            self?.rebuildReceiversMenu()
        }
    }

    private func requestScreenCapturePermission() async {
        if #available(macOS 14.0, *) {
            do {
                // This will prompt for permission if not already granted
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                print("ExternalScreen Mac: Screen capture permission granted")
            } catch {
                print("ExternalScreen Mac: Screen capture permission denied or error: \(error)")
                showAlert(
                    title: "Screen Recording Permission Required",
                    message: "Please grant screen recording permission in System Settings > Privacy & Security > Screen Recording"
                )
            }
        }
    }

    // MARK: - Actions

    @objc private func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.show()
    }

    /// Called by MainWindow toggle button
    func togglePipeline() {
        if isRunning {
            stopPipeline()
        } else {
            startPipeline()
        }
    }

    /// Called by MainWindow when resolution picker changes
    func setPreset(_ preset: DisplayPreset) {
        guard targetKind == .iPad else {
            log("Preset change ignored: Mac receiver uses native resolution")
            return
        }
        guard preset != currentPreset else { return }

        log("setPreset: Setting preset to \(preset.rawValue) (\(preset.description))")

        // Update menu checkmarks
        for (index, item) in presetMenuItems.enumerated() {
            let presets = DisplayPreset.allCases
            item.state = (index < presets.count && presets[index] == preset) ? .on : .off
        }

        currentPreset = preset
        print("ExternalScreen: Preset changed to \(preset.rawValue) (\(preset.description))")

        // If running, restart the pipeline with new resolution
        if isRunning {
            log("setPreset: Restarting pipeline with new resolution...")
            restartWithNewPreset()
        } else {
            // Reinitialize components with new preset so they're ready when we start
            log("setPreset: Reinitializing components with new preset...")
            reinitializeComponentsWithCurrentPreset()
        }
    }

    @objc func startPipeline() {
        guard !isRunning else {
            log("startPipeline: Already running")
            return
        }

        log("startPipeline: Starting...")
        updateStatus("Starting...")

        // 1. Create virtual display (or verify it's still active)
        if !virtualDisplayManager.isActive {
            guard virtualDisplayManager.start() else {
                log("startPipeline: Failed to create virtual display")
                updateStatus("Failed to start")
                showAlert(title: "Error", message: "Failed to create virtual display")
                return
            }
            log("startPipeline: Virtual display created, ID=\(virtualDisplayManager.displayID)")
        } else {
            log("startPipeline: Virtual display already active, ID=\(virtualDisplayManager.displayID)")
        }

        // 2. Start USB device listener (or reconnect if already listening)
        log("startPipeline: Starting USB listener...")
        usbDeviceManager.startListening()
        receiverBrowser.start()

        // 3. If we had a previous connection, try to reconnect
        if !usbDeviceManager.connected {
            log("startPipeline: Attempting to reconnect to previously connected device...")
            usbDeviceManager.reconnect()
        }

        isRunning = true
        updateStatusIcon(connected: usbDeviceManager.connected)
        if usbDeviceManager.connected {
            updateStatus("Connected - Streaming", state: .connected)
        } else {
            updateStatus("Waiting for iPad...", state: .waiting)
        }
        log("startPipeline: Complete, waiting for iPad connection...")
    }

    @objc func stopPipeline() {
        guard isRunning else { return }

        print("ExternalScreen Mac: Stopping pipeline...")
        updateStatus("Stopping...")

        // Mark as not running first to prevent new frames from being processed
        isRunning = false

        // Stop capture and encoding, but keep USB listener active for reconnection
        if #available(macOS 14.0, *) {
            Task {
                await stopPipelineTeardown(stopVirtualDisplay: false)
            }
        } else {
            h264Encoder.stop()
            usbDeviceManager.disconnect()
            // Tear down any Mac receiver session
            receiverBrowser.stop()
            networkTransport?.disconnect()
            networkTransport = nil
            targetKind = .iPad
            isConnectingToReceiver = false
            // Keep virtual display active to preserve position settings

            updateStatusIcon(connected: false)
            updateStatus("Stopped", state: .idle)
            print("ExternalScreen Mac: Pipeline stopped (virtual display preserved)")
        }
    }

    /// Shared awaited teardown used by `stopPipeline()` and receiver-mode entry: waits
    /// for screen capture to fully stop, then performs the remaining synchronous
    /// teardown on the main actor.
    /// - Parameter stopVirtualDisplay: normal `stopPipeline()` preserves the virtual
    ///   display (keeps its screen arrangement/position); receiver-mode entry must fully
    ///   stop it, since this Mac is about to act as a screen rather than a host.
    @available(macOS 14.0, *)
    private func stopPipelineTeardown(stopVirtualDisplay: Bool) async {
        // Wait for screen capture to fully stop first
        await screenCaptureManager.stopCapture()

        // Then stop encoder on main thread
        await MainActor.run {
            h264Encoder.stop()
            // Disconnect USB channel but keep listener active for quick reconnect
            usbDeviceManager.disconnect()
            // Tear down any Mac receiver session
            receiverBrowser.stop()
            networkTransport?.disconnect()
            networkTransport = nil
            targetKind = .iPad
            isConnectingToReceiver = false

            if stopVirtualDisplay {
                virtualDisplayManager.stop()
            }
            // else: keep virtual display active to preserve position settings

            updateStatusIcon(connected: false)
            updateStatus("Stopped", state: .idle)
            print("ExternalScreen Mac: Pipeline stopped\(stopVirtualDisplay ? "" : " (virtual display preserved)")")
        }
    }

    // MARK: - Orientation Handling

    private func handleOrientationChange(_ orientation: ScreenOrientation) {
        guard targetKind == .iPad else { return }

        let newIsPortrait = (orientation == .portrait)
        guard newIsPortrait != isPortrait else {
            log("handleOrientationChange: Already in \(orientation), ignoring")
            return
        }

        log("handleOrientationChange: Changing to \(orientation)")
        isPortrait = newIsPortrait

        // Debounce rapid orientation changes
        orientationDebounceTask?.cancel()
        orientationDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if isRunning {
                    restartWithNewPreset()
                } else {
                    reinitializeComponentsWithCurrentPreset()
                }
            }
        }
    }

    // MARK: - Private Methods

    private func startCaptureAndEncoding() {
        log("startCaptureAndEncoding: Called, isRunning=\(isRunning)")
        guard isRunning else { return }

        let displayID = virtualDisplayManager.displayID
        log("startCaptureAndEncoding: displayID=\(displayID)")
        guard displayID != 0 else {
            log("startCaptureAndEncoding: ERROR - No display ID available")
            return
        }

        // Configure touch handler for this display
        touchEventHandler.setTargetDisplay(displayID)

        // Start encoder
        do {
            try h264Encoder.start()
            log("startCaptureAndEncoding: Encoder started")
        } catch {
            log("startCaptureAndEncoding: ERROR - Failed to start encoder: \(error)")
            return
        }

        // Start screen capture
        if #available(macOS 14.0, *) {
            Task {
                do {
                    log("startCaptureAndEncoding: Starting screen capture for display \(displayID)")
                    try await screenCaptureManager.startCapture(displayID: displayID)
                    log("startCaptureAndEncoding: Screen capture started successfully")
                } catch {
                    log("startCaptureAndEncoding: ERROR - Failed to start screen capture: \(error)")
                }
            }
        }

        log("startCaptureAndEncoding: Complete")
    }

    private func handleDisplayCapabilities(_ caps: DisplayCapabilitiesMessage, from transport: FrameTransport) {
        log("Receiver capabilities: \(caps.pixelWidth)x\(caps.pixelHeight) @\(caps.scale)x")

        if #available(macOS 14.0, *) {
            Task {
                await screenCaptureManager.stopCapture()
                await MainActor.run {
                    guard transport === self.networkTransport else {
                        log("handleDisplayCapabilities: Stale transport, aborting reconfiguration")
                        return
                    }

                    h264Encoder.stop()

                    let w = Int(caps.pixelWidth)
                    let h = Int(caps.pixelHeight)

                    let ok = virtualDisplayManager.reconfigureForReceiver(
                        pixelWidth: w, pixelHeight: h,
                        refreshRate: ExternalScreenConstants.defaultRefreshRate
                    )
                    log("reconfigureForReceiver(\(w)x\(h)) -> \(ok), displayID=\(virtualDisplayManager.displayID)")
                    guard ok else {
                        updateStatus("Failed to create display", state: .idle)
                        networkTransport?.disconnect()
                        // NetworkHostTransport.disconnect() sets connected=false synchronously, so the
                        // later .cancelled event sees wasConnected==false and never fires
                        // transportDidDisconnect. Reset these fields ourselves so the iPad path isn't
                        // permanently locked out by the transportDidConnect mutual-exclusion guard.
                        networkTransport = nil
                        targetKind = .iPad
                        reinitializeComponentsWithCurrentPreset()
                        if !virtualDisplayManager.isActive {
                            virtualDisplayManager.start()
                        }
                        return
                    }

                    // Bitrate: ~10 bits/pixel/sec, capped at 80 Mbps, floor 25 Mbps
                    let bitrate = min(80_000_000, max(25_000_000, w * h * 10))
                    h264Encoder = H264Encoder(
                        width: w, height: h,
                        frameRate: Int(ExternalScreenConstants.defaultRefreshRate),
                        bitrate: bitrate,
                        keyframeInterval: ExternalScreenConstants.keyframeInterval
                    )
                    h264Encoder.delegate = self

                    screenCaptureManager = ScreenCaptureManager(
                        width: w, height: h,
                        frameRate: Int(ExternalScreenConstants.defaultRefreshRate),
                        showsCursor: false  // cursor is streamed separately (Task 8)
                    )
                    screenCaptureManager.delegate = self

                    frameNumber = 0
                    didDropFrames = false
                    activeTransport.resetFlowControl()

                    let config = DisplayConfigMessage(
                        width: caps.pixelWidth,
                        height: caps.pixelHeight,
                        refreshRate: Float(ExternalScreenConstants.defaultRefreshRate)
                    )
                    activeTransport.sendMessage(type: .displayConfig, payload: config.toData())

                    // Give WindowServer/SCK a moment to register the reconfigured display
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await MainActor.run {
                            guard transport === self.networkTransport else {
                                self.log("handleDisplayCapabilities: Stale transport after delay, skipping startCaptureAndEncoding")
                                return
                            }
                            self.startCaptureAndEncoding()
                        }
                    }
                }
            }
        }
    }

    private func updateStatusIcon(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            if let button = self?.statusItem.button {
                if connected {
                    // Green checkmark when connected
                    if let image = NSImage(systemSymbolName: "checkmark.rectangle", accessibilityDescription: "Connected") {
                        image.isTemplate = false
                        button.image = image
                    } else {
                        button.title = "Connected"
                    }
                } else {
                    // Regular icon when not connected
                    if let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "External Screen") {
                        image.isTemplate = true
                        button.image = image
                    } else {
                        button.title = "ExtMon"
                    }
                }
            }
        }
    }

    /// Public accessor for MainWindow to read current preset
    var currentDisplayPreset: DisplayPreset { currentPreset }

    private func updateStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            (self?.mainWindowController?.window as? MainWindow)?.updateStatus(status)
        }
    }

    private func updateStatus(_ status: String, state: ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            (self?.mainWindowController?.window as? MainWindow)?.updateStatus(status, state: state)
        }
    }

    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - VirtualDisplayManagerDelegate

extension AppDelegate: VirtualDisplayManagerDelegate {
    func virtualDisplayDidConnect(displayID: CGDirectDisplayID) {
        print("ExternalScreen Mac: Virtual display connected with ID \(displayID)")
    }

    func virtualDisplayDidDisconnect() {
        print("ExternalScreen Mac: Virtual display disconnected")
    }
}

// MARK: - ScreenCaptureManagerDelegate

@available(macOS 14.0, *)
extension AppDelegate: ScreenCaptureManagerDelegate {
    func screenCaptureManager(_ manager: ScreenCaptureManager, didCapture sampleBuffer: CMSampleBuffer) {
        // Forward to encoder
        h264Encoder.encode(sampleBuffer: sampleBuffer)
    }

    func screenCaptureManager(_ manager: ScreenCaptureManager, didCapture pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        // Forward pixel buffer directly to encoder
        h264Encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }

    func screenCaptureManager(_ manager: ScreenCaptureManager, didFailWithError error: Error) {
        print("ExternalScreen Mac: Screen capture error: \(error)")
    }
}

// MARK: - H264EncoderDelegate

extension AppDelegate: H264EncoderDelegate {
    func h264Encoder(_ encoder: H264Encoder, didEncode data: Data, isKeyframe: Bool, presentationTime: CMTime) {
        // Flow control: drop P-frames when pipe is congested, always send keyframes
        if !isKeyframe && !activeTransport.canSendFrame() {
            activeTransport.incrementDroppedFrames()
            didDropFrames = true
            // Log periodically
            if activeTransport.droppedFrameCount % 30 == 1 {
                log("FlowControl: Dropped \(activeTransport.droppedFrameCount) frames total")
            }
            frameNumber += 1
            return
        }

        // After dropping frames, force a keyframe so decoder gets a clean reference
        // (dropped P-frames break the decoder's reference chain, causing pixelation)
        if didDropFrames && !isKeyframe {
            didDropFrames = false
            h264Encoder.forceKeyframe()
        } else if isKeyframe {
            didDropFrames = false
        }

        // Log every 120 frames (about once per second at 120fps)
        if frameNumber % 120 == 0 {
            log("Encoder: Frame \(frameNumber), size=\(data.count), keyframe=\(isKeyframe), dropped=\(activeTransport.droppedFrameCount)")
        }

        // Send to connected iPad
        let pts = UInt64(presentationTime.seconds * 1_000_000)
        activeTransport.sendFrame(
            frameData: data,
            frameNumber: frameNumber,
            isKeyframe: isKeyframe,
            presentationTime: pts
        )
        frameNumber += 1
    }

    func h264Encoder(_ encoder: H264Encoder, didFailWithError error: Error) {
        log("Encoder: ERROR - \(error)")
    }
}

// MARK: - FrameTransportDelegate

extension AppDelegate: FrameTransportDelegate {
    func transportDidConnect(_ transport: FrameTransport, endpointName: String) {
        if transport === usbDeviceManager && targetKind == .macReceiver {
            log("iPad connect ignored during Mac receiver session")
            usbDeviceManager.disconnect()
            return
        }

        log("Transport: connected to \(endpointName)")
        updateStatusIcon(connected: true)
        updateStatus("Connected - Streaming", state: .connected)

        transport.resetFlowControl()
        frameNumber = 0

        if transport === networkTransport {
            // Mac receiver: wait for displayCapabilities before configuring anything.
            log("Transport: Mac receiver connected, waiting for display capabilities...")
            return
        }

        // iPad path (unchanged)
        let config = DisplayConfigMessage(
            width: UInt32(effectiveWidth),
            height: UInt32(effectiveHeight),
            refreshRate: Float(virtualDisplayManager.refreshRate)
        )
        log("Transport: Sending display config \(effectiveWidth)x\(effectiveHeight)")
        transport.sendMessage(type: .displayConfig, payload: config.toData())
        startCaptureAndEncoding()
    }

    func transportDidDisconnect(_ transport: FrameTransport) {
        log("Transport: disconnected")

        let wasMacReceiver = transport === networkTransport
        if wasMacReceiver {
            networkTransport = nil
            targetKind = .iPad
            isConnectingToReceiver = false
        }

        updateStatusIcon(connected: false)
        updateStatus("Disconnected", state: isRunning ? .waiting : .idle)

        if #available(macOS 14.0, *) {
            Task {
                await screenCaptureManager.stopCapture()
                await MainActor.run {
                    h264Encoder.stop()
                    frameNumber = 0
                    if wasMacReceiver {
                        // A Mac-receiver session left Mac-native-sized components behind;
                        // rebuild at the current iPad preset so the next iPad connect isn't mismatched.
                        reinitializeComponentsWithCurrentPreset()
                        if !virtualDisplayManager.isActive {
                            virtualDisplayManager.start()
                        }
                    }
                    if isRunning {
                        updateStatus("Waiting for connection...", state: .waiting)
                    }
                }
            }
        }
    }

    func transport(_ transport: FrameTransport, didReceive data: Data) {
        guard let header = MessageHeader.from(data: data) else {
            print("ExternalScreen Mac: Invalid message header")
            return
        }

        let payloadStart = MessageHeader.size
        let payload = data.subdata(in: payloadStart..<data.count)

        switch header.type {
        case .touchBegan, .touchMoved, .touchEnded, .touchCancelled:
            if let touch = TouchEventMessage.from(data: payload) {
                touchEventHandler.handleTouch(type: header.type, touch: touch)
            }

        case .frameAck:
            if let ack = FrameAckMessage.from(data: payload) {
                usbDeviceManager.acknowledgeFrame(ack.frameNumber)
            }

        case .orientationChange:
            if let orientationMsg = OrientationMessage.from(data: payload) {
                handleOrientationChange(orientationMsg.orientation)
            }

        case .displayCapabilities:
            if let caps = DisplayCapabilitiesMessage.from(data: payload) {
                handleDisplayCapabilities(caps, from: transport)
            }

        default:
            print("ExternalScreen Mac: Received message type: \(header.type)")
        }
    }
}

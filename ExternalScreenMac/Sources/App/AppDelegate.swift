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

    // State
    private var isRunning = false
    private var frameNumber: UInt32 = 0
    private var didDropFrames = false  // Track if we dropped frames and need a keyframe
    private var currentPreset: DisplayPreset = ExternalScreenConstants.defaultPreset
    private var presetMenuItems: [NSMenuItem] = []

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

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "w"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
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

    private func reinitializeComponentsWithCurrentPreset() {
        // Reinitialize managers with current preset
        virtualDisplayManager = VirtualDisplayManager(preset: currentPreset)
        virtualDisplayManager.delegate = self

        if #available(macOS 14.0, *) {
            screenCaptureManager = ScreenCaptureManager(preset: currentPreset)
            screenCaptureManager.delegate = self
        }

        h264Encoder = H264Encoder(preset: currentPreset)
        h264Encoder.delegate = self

        print("ExternalScreen Mac: Components reinitialized with preset \(currentPreset.rawValue) (\(currentPreset.description))")
    }

    private func restartWithNewPreset() {
        // Stop current capture and encoding
        if #available(macOS 14.0, *) {
            Task {
                await screenCaptureManager.stopCapture()
                h264Encoder.stop()

                // Update virtual display resolution (keeps same display ID and USB connection)
                let updated = virtualDisplayManager.updateResolution(preset: currentPreset)
                log("restartWithNewPreset: updateResolution(\(currentPreset.description)) -> \(updated)")

                // Recreate encoder and capture manager with new preset
                h264Encoder = H264Encoder(preset: currentPreset)
                h264Encoder.delegate = self

                screenCaptureManager = ScreenCaptureManager(preset: currentPreset)
                screenCaptureManager.delegate = self

                // Reset frame counter for clean restart
                frameNumber = 0
                didDropFrames = false
                usbDeviceManager.resetFlowControl()

                // Restart if iPad is connected
                if usbDeviceManager.connected {
                    // Send updated display config
                    let config = DisplayConfigMessage(
                        width: UInt32(currentPreset.width),
                        height: UInt32(currentPreset.height),
                        refreshRate: Float(ExternalScreenConstants.defaultRefreshRate)
                    )
                    usbDeviceManager.sendMessage(type: .displayConfig, payload: config.toData())

                    // Wait for ScreenCaptureKit to detect the updated display
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    // Restart capture and encoding
                    startCaptureAndEncoding()
                }

                log("restartWithNewPreset: Complete - now using \(currentPreset.description)")
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
        usbDeviceManager.delegate = self

        touchEventHandler = TouchEventHandler()

        print("ExternalScreen Mac: Components initialized with preset \(currentPreset.rawValue) (\(currentPreset.description))")
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

    /// Called by MainWindow when resolution picker changes
    func setPreset(_ preset: DisplayPreset) {
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

        // 3. If we had a previous connection, try to reconnect
        if !usbDeviceManager.connected {
            log("startPipeline: Attempting to reconnect to previously connected device...")
            usbDeviceManager.reconnect()
        }

        isRunning = true
        updateStatusIcon(connected: usbDeviceManager.connected)
        updateStatus(usbDeviceManager.connected ? "Connected - Streaming" : "Waiting for iPad...")
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
                // Wait for screen capture to fully stop first
                await screenCaptureManager.stopCapture()

                // Then stop encoder on main thread
                await MainActor.run {
                    h264Encoder.stop()
                    // Disconnect USB channel but keep listener active for quick reconnect
                    usbDeviceManager.disconnect()
                    // Keep virtual display active to preserve position settings
                    // virtualDisplayManager.stop() - commented out to preserve position

                    updateStatusIcon(connected: false)
                    updateStatus("Stopped")
                    print("ExternalScreen Mac: Pipeline stopped (virtual display preserved)")
                }
            }
        } else {
            h264Encoder.stop()
            usbDeviceManager.disconnect()
            // Keep virtual display active to preserve position settings

            updateStatusIcon(connected: false)
            updateStatus("Stopped")
            print("ExternalScreen Mac: Pipeline stopped (virtual display preserved)")
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

    private func updateStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            (self?.mainWindowController?.window as? MainWindow)?.updateStatus(status)
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
        if !isKeyframe && !usbDeviceManager.canSendFrame() {
            usbDeviceManager.incrementDroppedFrames()
            didDropFrames = true
            // Log periodically
            if usbDeviceManager.droppedFrameCount % 30 == 1 {
                log("FlowControl: Dropped \(usbDeviceManager.droppedFrameCount) frames total")
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
            log("Encoder: Frame \(frameNumber), size=\(data.count), keyframe=\(isKeyframe), dropped=\(usbDeviceManager.droppedFrameCount)")
        }

        // Send to connected iPad
        let pts = UInt64(presentationTime.seconds * 1_000_000)
        usbDeviceManager.sendFrame(
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

// MARK: - USBDeviceManagerDelegate

extension AppDelegate: USBDeviceManagerDelegate {
    func usbDeviceManager(_ manager: USBDeviceManager, didConnect deviceID: Int) {
        log("USB: iPad connected (device ID: \(deviceID))")

        updateStatusIcon(connected: true)
        updateStatus("Connected - Streaming")

        // Reset flow control for fresh connection
        usbDeviceManager.resetFlowControl()
        frameNumber = 0

        // Send display configuration
        let config = DisplayConfigMessage(
            width: UInt32(virtualDisplayManager.width),
            height: UInt32(virtualDisplayManager.height),
            refreshRate: Float(virtualDisplayManager.refreshRate)
        )
        log("USB: Sending display config \(virtualDisplayManager.width)x\(virtualDisplayManager.height)")
        manager.sendMessage(type: .displayConfig, payload: config.toData())

        // Start capture and encoding
        startCaptureAndEncoding()
    }

    func usbDeviceManager(_ manager: USBDeviceManager, didDisconnect deviceID: Int) {
        log("USB: iPad disconnected (device ID: \(deviceID))")

        updateStatusIcon(connected: false)
        updateStatus("iPad disconnected")

        // Stop capture but keep virtual display
        if #available(macOS 14.0, *) {
            Task {
                await screenCaptureManager.stopCapture()
                await MainActor.run {
                    h264Encoder.stop()
                    frameNumber = 0
                    // Update status after cleanup is done
                    if isRunning {
                        updateStatus("Waiting for iPad...")
                    }
                }
            }
        } else {
            h264Encoder.stop()
            frameNumber = 0
            if isRunning {
                updateStatus("Waiting for iPad...")
            }
        }
    }

    func usbDeviceManager(_ manager: USBDeviceManager, didReceive data: Data, fromDevice deviceID: Int) {
        // Parse received message
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

        default:
            print("ExternalScreen Mac: Received message type: \(header.type)")
        }
    }

    func usbDeviceManager(_ manager: USBDeviceManager, didFailWithError error: Error) {
        print("ExternalScreen Mac: USB error: \(error)")
    }
}

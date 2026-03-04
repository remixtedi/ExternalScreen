import UIKit
import MetalKit
import CoreMedia

/// Main view controller for the iPad display app
final class DisplayViewController: UIViewController {

    // MARK: - Properties

    // UI
    private var metalView: MTKView!
    private var touchCaptureView: TouchCaptureView!
    private var statusLabel: UILabel!
    private var connectionIndicator: UIView!

    // Core components
    private var usbConnectionManager: USBConnectionManager!
    private var h264Decoder: H264Decoder!
    private var metalRenderer: MetalRenderer?

    // State
    private var displayConfig: DisplayConfigMessage?
    private var frameCount: UInt32 = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        setupComponents()
        startListening()
        setupNotifications()
    }

    private func setupNotifications() {
        // Handle memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // Handle app going to background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Handle app coming to foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        print("DisplayViewController: Received memory warning, clearing resources")
        metalRenderer?.clear()
    }

    @objc private func handleDidEnterBackground() {
        print("DisplayViewController: App entering background, pausing rendering")
        metalView?.isPaused = true
        metalRenderer?.clear()
    }

    @objc private func handleWillEnterForeground() {
        print("DisplayViewController: App entering foreground, resuming rendering")
        metalView?.isPaused = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Hide status bar for full screen
        setNeedsStatusBarAppearanceUpdate()
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .black

        // Metal view for rendering
        metalView = MTKView(frame: view.bounds)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.backgroundColor = .black
        view.addSubview(metalView)

        // Touch capture view (on top of Metal view)
        touchCaptureView = TouchCaptureView(frame: view.bounds)
        touchCaptureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        touchCaptureView.delegate = self
        view.addSubview(touchCaptureView)

        // Status overlay
        setupStatusOverlay()
    }

    private func setupStatusOverlay() {
        // Semi-transparent status bar at top
        let statusBar = UIView()
        statusBar.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)

        // Connection indicator dot
        connectionIndicator = UIView()
        connectionIndicator.backgroundColor = .systemRed
        connectionIndicator.layer.cornerRadius = 5
        connectionIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(connectionIndicator)

        // Status label
        statusLabel = UILabel()
        statusLabel.text = "Waiting for Mac connection..."
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 30),

            connectionIndicator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            connectionIndicator.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            connectionIndicator.widthAnchor.constraint(equalToConstant: 10),
            connectionIndicator.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: connectionIndicator.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])

        // Fade out status bar after initial display
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.fadeStatusBar(show: false)
        }
    }

    private func setupComponents() {
        // Initialize Metal renderer
        metalRenderer = MetalRenderer(metalView: metalView)

        // Initialize decoder
        h264Decoder = H264Decoder()
        h264Decoder.delegate = self

        // Initialize USB manager
        usbConnectionManager = USBConnectionManager()
        usbConnectionManager.delegate = self

        print("DisplayViewController: Components initialized")
    }

    private func startListening() {
        print("DisplayViewController: Starting USB listener")
        usbConnectionManager.startListening()
    }

    // MARK: - UI Updates

    private func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.connectionIndicator.backgroundColor = connected ? .systemGreen : .systemRed

            if connected {
                self.statusLabel.text = "Connected to Mac"
            } else {
                self.statusLabel.text = "Waiting for Mac connection..."
                self.metalRenderer?.clear()
            }

            // Show status bar briefly
            self.fadeStatusBar(show: true)

            if connected {
                // Hide again after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.fadeStatusBar(show: false)
                }
            }
        }
    }

    private func fadeStatusBar(show: Bool) {
        guard let statusBar = statusLabel.superview else { return }

        UIView.animate(withDuration: 0.3) {
            statusBar.alpha = show ? 1.0 : 0.0
        }
    }

    // Show status bar when tapping
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        if usbConnectionManager.connected {
            fadeStatusBar(show: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.fadeStatusBar(show: false)
            }
        }
    }
}

// MARK: - USBConnectionManagerDelegate

extension DisplayViewController: USBConnectionManagerDelegate {
    func connectionManager(_ manager: USBConnectionManager, didConnect port: UInt16) {
        print("DisplayViewController: Connected to Mac on port \(port)")
        updateConnectionStatus(connected: true)
    }

    func connectionManager(_ manager: USBConnectionManager, didDisconnect error: Error?) {
        print("DisplayViewController: Disconnected from Mac. Error: \(String(describing: error))")
        updateConnectionStatus(connected: false)
        h264Decoder.reset()
        frameCount = 0
    }

    private static var messageCount = 0

    func connectionManager(_ manager: USBConnectionManager, didReceive data: Data) {
        Self.messageCount += 1

        // Parse message header
        guard data.count >= MessageHeader.size else {
            print("DisplayViewController: Message too small: \(data.count) bytes")
            return
        }
        guard let header = MessageHeader.from(data: data) else {
            print("DisplayViewController: Failed to parse message header")
            return
        }

        let payloadStart = MessageHeader.size
        let payload = data.subdata(in: payloadStart..<data.count)

        // Log first few messages
        if Self.messageCount <= 5 {
            print("DisplayViewController: Message #\(Self.messageCount) type=\(header.type) payload=\(payload.count) bytes")
        }

        switch header.type {
        case .displayConfig:
            if let config = DisplayConfigMessage.from(data: payload) {
                handleDisplayConfig(config)
            }

        case .frameData:
            if payload.count >= FrameDataHeader.size {
                let frameHeader = FrameDataHeader.from(data: payload)
                let frameData = payload.subdata(in: FrameDataHeader.size..<payload.count)
                handleFrameData(frameHeader: frameHeader, data: frameData)
            } else {
                print("DisplayViewController: Frame payload too small: \(payload.count) bytes")
            }

        case .disconnect:
            manager.disconnect()

        default:
            print("DisplayViewController: Received unknown message type: \(header.type)")
        }
    }

    func connectionManager(_ manager: USBConnectionManager, didFailWithError error: Error) {
        print("DisplayViewController: USB error: \(error)")
    }

    private func handleDisplayConfig(_ config: DisplayConfigMessage) {
        print("DisplayViewController: Display config received: \(config.width)x\(config.height) @ \(config.refreshRate)Hz")

        // Reset decoder if resolution changed so it accepts new SPS/PPS
        if let oldConfig = displayConfig,
           oldConfig.width != config.width || oldConfig.height != config.height {
            print("DisplayViewController: Resolution changed from \(oldConfig.width)x\(oldConfig.height) to \(config.width)x\(config.height), resetting decoder")
            h264Decoder.reset()
            metalRenderer?.clear()
            frameCount = 0
        }

        displayConfig = config

        // Update decoder frame rate for proper timing
        h264Decoder.setFrameRate(Int(config.refreshRate))

        // Update status
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "Connected: \(config.width)x\(config.height) @ \(Int(config.refreshRate))Hz"
        }
    }

    private func handleFrameData(frameHeader: FrameDataHeader?, data: Data) {
        guard !data.isEmpty else {
            print("DisplayViewController: Empty frame data")
            return
        }

        let pts = frameHeader?.presentationTime ?? UInt64(frameCount) * 16667

        // Log every 30 frames, or first 5 frames
        if frameCount % 30 == 0 || frameCount < 5 {
            print("DisplayViewController: Frame \(frameCount), size=\(data.count), keyframe=\(frameHeader?.isKeyframe ?? false)")
            // Log first 16 bytes to check H264 format
            let preview = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("DisplayViewController: Frame data preview: \(preview)")
        }

        // Decode the frame
        h264Decoder.decode(data: data, presentationTime: pts)

        // Send acknowledgment
        if let frameHeader = frameHeader {
            usbConnectionManager.sendFrameAck(frameNumber: frameHeader.frameNumber)
        }

        frameCount += 1
    }
}

// MARK: - H264DecoderDelegate

extension DisplayViewController: H264DecoderDelegate {
    private static var decodedFrameCount = 0

    func h264Decoder(_ decoder: H264Decoder, didDecode pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        Self.decodedFrameCount += 1

        // Log every 30 decoded frames
        if Self.decodedFrameCount % 30 == 0 {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("DisplayViewController: Decoded frame \(Self.decodedFrameCount), \(width)x\(height)")
        }

        // Display the frame
        metalRenderer?.display(pixelBuffer: pixelBuffer)
    }

    func h264Decoder(_ decoder: H264Decoder, didFailWithError error: Error) {
        print("DisplayViewController: Decoder error: \(error)")
    }
}

// MARK: - TouchCaptureViewDelegate

extension DisplayViewController: TouchCaptureViewDelegate {
    func touchCaptureView(_ view: TouchCaptureView, didBeginTouch touch: TouchEventMessage) {
        usbConnectionManager.sendTouch(type: .touchBegan, touch: touch)
    }

    func touchCaptureView(_ view: TouchCaptureView, didMoveTouch touch: TouchEventMessage) {
        usbConnectionManager.sendTouch(type: .touchMoved, touch: touch)
    }

    func touchCaptureView(_ view: TouchCaptureView, didEndTouch touch: TouchEventMessage) {
        usbConnectionManager.sendTouch(type: .touchEnded, touch: touch)
    }

    func touchCaptureView(_ view: TouchCaptureView, didCancelTouch touch: TouchEventMessage) {
        usbConnectionManager.sendTouch(type: .touchCancelled, touch: touch)
    }
}

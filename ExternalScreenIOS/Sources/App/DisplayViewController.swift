import UIKit
import MetalKit
import CoreMedia

/// Main view controller for the iPad display app
final class DisplayViewController: UIViewController {

    // MARK: - Properties

    // UI
    private var metalView: MTKView!
    private var touchCaptureView: TouchCaptureView!
    private var waitingView: ConnectionWaitingView!
    private var statusPill: UIVisualEffectView!
    private var statusDot: UIView!
    private var statusLabel: UILabel!
    private var statusPillHideTimer: Timer?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

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

        // Waiting view (between touch capture and status pill)
        waitingView = ConnectionWaitingView(frame: view.bounds)
        waitingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(waitingView)

        // Status pill overlay
        setupStatusPill()
    }

    private func setupStatusPill() {
        let blur = UIBlurEffect(style: .systemUltraThinMaterialDark)
        statusPill = UIVisualEffectView(effect: blur)
        statusPill.layer.cornerRadius = 18
        statusPill.clipsToBounds = true
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.alpha = 0
        view.addSubview(statusPill)

        let pillContent = statusPill.contentView

        // Status dot
        statusDot = UIView()
        statusDot.backgroundColor = .systemRed
        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        // Status label
        statusLabel = UILabel()
        statusLabel.text = "Waiting for Mac connection..."
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        pillContent.addSubview(statusDot)
        pillContent.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusPill.heightAnchor.constraint(equalToConstant: 36),

            statusDot.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: 20),
            statusDot.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
        ])
    }

    private func setupComponents() {
        metalRenderer = MetalRenderer(metalView: metalView)
        h264Decoder = H264Decoder()
        h264Decoder.delegate = self
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

            self.statusDot.backgroundColor = connected ? .systemGreen : .systemRed

            if connected {
                self.statusLabel.text = "Connected to Mac"
                self.waitingView.hide(animated: true)
                self.showStatusPill(autoHide: true)
            } else {
                self.statusLabel.text = "Waiting for Mac connection..."
                self.waitingView.show()
                self.metalRenderer?.clear()
                self.showStatusPill(autoHide: false)
            }
        }
    }

    private func showStatusPill(autoHide: Bool) {
        statusPillHideTimer?.invalidate()
        statusPillHideTimer = nil

        UIView.animate(withDuration: 0.3) {
            self.statusPill.alpha = 1.0
        }

        if autoHide {
            statusPillHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                UIView.animate(withDuration: 0.3) {
                    self?.statusPill.alpha = 0.0
                }
            }
        }
    }

    private func hideStatusPill() {
        statusPillHideTimer?.invalidate()
        statusPillHideTimer = nil
        UIView.animate(withDuration: 0.3) {
            self.statusPill.alpha = 0.0
        }
    }

    // Show status pill when tapping during streaming
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        if usbConnectionManager.connected {
            showStatusPill(autoHide: true)
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

        if let oldConfig = displayConfig,
           oldConfig.width != config.width || oldConfig.height != config.height {
            print("DisplayViewController: Resolution changed from \(oldConfig.width)x\(oldConfig.height) to \(config.width)x\(config.height), resetting decoder")
            h264Decoder.reset()
            metalRenderer?.clear()
            frameCount = 0
        }

        displayConfig = config
        h264Decoder.setFrameRate(Int(config.refreshRate))

        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "\(config.width)x\(config.height) @ \(Int(config.refreshRate))Hz"
            self?.showStatusPill(autoHide: true)
        }
    }

    private func handleFrameData(frameHeader: FrameDataHeader?, data: Data) {
        guard !data.isEmpty else {
            print("DisplayViewController: Empty frame data")
            return
        }

        let pts = frameHeader?.presentationTime ?? UInt64(frameCount) * 16667

        if frameCount % 30 == 0 || frameCount < 5 {
            print("DisplayViewController: Frame \(frameCount), size=\(data.count), keyframe=\(frameHeader?.isKeyframe ?? false)")
            let preview = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("DisplayViewController: Frame data preview: \(preview)")
        }

        h264Decoder.decode(data: data, presentationTime: pts)

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

        if Self.decodedFrameCount % 30 == 0 {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("DisplayViewController: Decoded frame \(Self.decodedFrameCount), \(width)x\(height)")
        }

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

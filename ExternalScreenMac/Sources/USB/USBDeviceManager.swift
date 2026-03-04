import Foundation

/// Delegate for USB device events
protocol USBDeviceManagerDelegate: AnyObject {
    func usbDeviceManager(_ manager: USBDeviceManager, didConnect deviceID: Int)
    func usbDeviceManager(_ manager: USBDeviceManager, didDisconnect deviceID: Int)
    func usbDeviceManager(_ manager: USBDeviceManager, didReceive data: Data, fromDevice deviceID: Int)
    func usbDeviceManager(_ manager: USBDeviceManager, didFailWithError error: Error)
}

/// Manages USB device discovery and communication using PeerTalk
/// Mac uses PTUSBHub to detect iOS devices and CONNECTS to them
final class USBDeviceManager: NSObject {

    // MARK: - Properties

    weak var delegate: USBDeviceManagerDelegate?

    private var peerChannel: PTChannel?
    private var connectedDeviceID: NSNumber?
    private var isListening = false

    /// Whether an iPad is currently connected
    var connected: Bool {
        return connectedDeviceID != nil && peerChannel != nil
    }
    private var notificationObservers: [NSObjectProtocol] = []
    private var connectingDeviceID: NSNumber?

    private let port: Int32
    private let frameType: UInt32 = 101
    /// Serial queue for processing received messages (touch events) off the main thread
    private let receiveQueue = DispatchQueue(label: "com.externalscreen.usb.receive")

    // MARK: - Flow Control

    /// Last frame number sent to iPad
    private var lastSentFrameNumber: UInt32 = 0

    /// Last frame number acknowledged by iPad
    private var lastAckedFrameNumber: UInt32 = 0

    /// Lock protecting flow control state
    private let flowControlLock = NSLock()

    /// Number of dropped frames (for debug logging)
    private(set) var droppedFrameCount: UInt64 = 0

    // MARK: - Initialization

    init(port: UInt16 = ExternalScreenConstants.usbPort) {
        self.port = Int32(port)
        super.init()
    }

    deinit {
        stopListening()
    }

    // MARK: - Public Methods

    /// Starts listening for iOS device connections
    func startListening() {
        guard !isListening else {
            // Already listening, but check for attached devices we might have missed
            log("USBDeviceManager: Already listening, scanning for attached devices...")
            scanForAttachedDevices()
            return
        }

        log("USBDeviceManager: Starting to screen for USB devices on port \(port)")

        // IMPORTANT: Register observers BEFORE accessing PTUSBHub.shared()
        // because PTUSBHub sends notifications for already-attached devices immediately

        // Listen for device attach notifications (use nil object to catch all)
        let attachObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PTUSBDeviceDidAttachNotification"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDeviceAttached(notification)
        }
        notificationObservers.append(attachObserver)

        // Listen for device detach notifications
        let detachObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PTUSBDeviceDidDetachNotification"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDeviceDetached(notification)
        }
        notificationObservers.append(detachObserver)

        isListening = true
        log("USBDeviceManager: Notification observers registered")

        // NOW initialize the PTUSBHub - this will trigger notifications for already-attached devices
        // Access sharedHub to ensure it starts listening
        let _ = PTUSBHub.shared()

        log("USBDeviceManager: PTUSBHub initialized, listening for USB device connections...")
    }

    /// Scans for already-attached USB devices and attempts to connect
    /// This is useful when restarting the pipeline while a device is already connected
    private func scanForAttachedDevices() {
        log("USBDeviceManager: Scanning for attached devices...")

        // If we have a last known device, try to reconnect to it
        if let deviceID = lastKnownDeviceID {
            log("USBDeviceManager: Found last known device \(deviceID), attempting reconnection...")
            connectToDevice(deviceID)
        }

        // PTUSBHub maintains a list of attached devices internally
        // We need to manually trigger device enumeration
        // The hub sends PTUSBDeviceDidAttachNotification for each attached device
        // but only on first initialization. We need to force re-enumeration.

        // Workaround: Manually broadcast a request to re-enumerate
        // This is done by posting to the hub's internal notification
        NotificationCenter.default.post(
            name: NSNotification.Name("PTUSBHubDidRestoreAttachedDevicesNotification"),
            object: PTUSBHub.shared()
        )
    }

    /// Stops listening for connections
    func stopListening() {
        guard isListening else { return }

        log("USBDeviceManager: Stopping listener")

        // Remove notification observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        // Close channel
        peerChannel?.close()
        peerChannel = nil
        connectedDeviceID = nil
        connectingDeviceID = nil

        isListening = false
    }

    /// Disconnects the current channel but keeps listening for devices
    /// This allows reconnection without losing track of attached devices
    func disconnect() {
        log("USBDeviceManager: Disconnecting channel (keeping listener active)")

        peerChannel?.close()
        peerChannel = nil

        let deviceID = connectedDeviceID
        connectedDeviceID = nil
        connectingDeviceID = nil

        // Store the last known device ID for potential reconnection
        if let deviceID = deviceID {
            lastKnownDeviceID = deviceID
        }
    }

    /// Attempts to reconnect to the last known device or any attached device
    func reconnect() {
        log("USBDeviceManager: Attempting to reconnect...")

        // If we have a last known device, try to connect to it
        if let deviceID = lastKnownDeviceID {
            log("USBDeviceManager: Reconnecting to last known device \(deviceID)")
            connectToDevice(deviceID)
        }
    }

    private var lastKnownDeviceID: NSNumber?

    /// Sends data to the connected iOS device
    @discardableResult
    func send(data: Data) -> Bool {
        guard let channel = peerChannel else {
            return false
        }

        channel.sendFrame(type: frameType, tag: 0, payload: data) { error in
            if let error = error {
                self.log("USBDeviceManager: Send error: \(error)")
            }
        }

        return true
    }

    /// Sends a message with header and payload
    func sendMessage(type: MessageType, payload: Data) {
        let header = MessageHeader(
            type: type,
            timestamp: currentTimestamp(),
            payloadLength: UInt32(payload.count)
        )

        var message = header.toData()
        message.append(payload)
        send(data: message)
    }

    /// Sends a video frame
    func sendFrame(frameData: Data, frameNumber: UInt32, isKeyframe: Bool, presentationTime: UInt64) {
        let frameHeader = FrameDataHeader(
            frameNumber: frameNumber,
            isKeyframe: isKeyframe,
            presentationTime: presentationTime
        )

        var payload = frameHeader.toData()
        payload.append(frameData)

        sendMessage(type: .frameData, payload: payload)

        flowControlLock.lock()
        lastSentFrameNumber = frameNumber
        flowControlLock.unlock()
    }

    /// Checks whether the pipeline can accept a new frame without exceeding the in-flight limit
    func canSendFrame() -> Bool {
        flowControlLock.lock()
        let inFlight = lastSentFrameNumber &- lastAckedFrameNumber
        flowControlLock.unlock()
        return inFlight <= ExternalScreenConstants.maxInFlightFrames
    }

    /// Records that a frame ack was received from the iPad
    func acknowledgeFrame(_ frameNumber: UInt32) {
        flowControlLock.lock()
        // Only advance forward (handle wrap-around with unsigned comparison)
        if frameNumber &- lastAckedFrameNumber < 0x8000_0000 {
            lastAckedFrameNumber = frameNumber
        }
        flowControlLock.unlock()
    }

    /// Resets flow control state (call on new connection)
    func resetFlowControl() {
        flowControlLock.lock()
        lastSentFrameNumber = 0
        lastAckedFrameNumber = 0
        droppedFrameCount = 0
        flowControlLock.unlock()
    }

    /// Increments the dropped frame counter
    func incrementDroppedFrames() {
        flowControlLock.lock()
        droppedFrameCount += 1
        flowControlLock.unlock()
    }

    /// Whether a device is currently connected
    var isConnected: Bool {
        peerChannel != nil
    }

    // MARK: - Device Handling

    private func handleDeviceAttached(_ notification: Notification) {
        log("USBDeviceManager: Received device attach notification")

        guard let userInfo = notification.userInfo,
              let deviceID = userInfo["DeviceID"] as? NSNumber else {
            log("USBDeviceManager: Device attached but no device ID in userInfo: \(String(describing: notification.userInfo))")
            return
        }

        log("USBDeviceManager: Device attached with ID \(deviceID)")

        // Log device properties if available
        if let properties = userInfo["Properties"] as? [String: Any] {
            log("USBDeviceManager: Device properties: \(properties)")
        }

        // Connect to the device
        connectToDevice(deviceID)
    }

    private func handleDeviceDetached(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let deviceID = userInfo["DeviceID"] as? NSNumber else {
            log("USBDeviceManager: Device detached but no device ID")
            return
        }

        log("USBDeviceManager: Device detached with ID \(deviceID)")

        if deviceID == connectedDeviceID {
            disconnectFromCurrentDevice()
        }

        if deviceID == connectingDeviceID {
            connectingDeviceID = nil
        }
    }

    private func connectToDevice(_ deviceID: NSNumber) {
        // Don't reconnect if already connected to this device
        if connectedDeviceID == deviceID && peerChannel != nil {
            log("USBDeviceManager: Already connected to device \(deviceID)")
            return
        }

        // Don't try to connect if we're already connecting to this device
        if connectingDeviceID == deviceID {
            log("USBDeviceManager: Already connecting to device \(deviceID)")
            return
        }

        // Close existing connection
        if let existingChannel = peerChannel {
            existingChannel.close()
            peerChannel = nil
            connectedDeviceID = nil
        }

        log("USBDeviceManager: Connecting to device \(deviceID) on port \(port)...")
        connectingDeviceID = deviceID

        let channel = PTChannel(protocol: nil, delegate: self)
        channel.connect(to: port, over: PTUSBHub.shared(), deviceID: deviceID) { [weak self] error in
            guard let self = self else { return }

            self.connectingDeviceID = nil

            if let error = error {
                self.log("USBDeviceManager: Failed to connect to device \(deviceID): \(error)")

                // Retry connection after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isListening else { return }
                    self.log("USBDeviceManager: Retrying connection to device \(deviceID)...")
                    self.connectToDevice(deviceID)
                }
            } else {
                self.log("USBDeviceManager: Connected to device \(deviceID)")
                self.peerChannel = channel
                self.connectedDeviceID = deviceID

                DispatchQueue.main.async {
                    self.delegate?.usbDeviceManager(self, didConnect: deviceID.intValue)
                }
            }
        }
    }

    private func disconnectFromCurrentDevice() {
        guard let deviceID = connectedDeviceID else { return }

        log("USBDeviceManager: Disconnecting from device \(deviceID)")

        peerChannel?.close()
        peerChannel = nil

        let id = deviceID.intValue
        connectedDeviceID = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.usbDeviceManager(self, didDisconnect: id)
        }
    }

    // MARK: - Utility

    private func currentTimestamp() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private func log(_ message: String) {
        print(message)
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
}

// MARK: - PTChannelDelegate

extension USBDeviceManager: PTChannelDelegate {

    func channel(_ channel: PTChannel, shouldAcceptFrame type: UInt32, tag: UInt32, payloadSize: UInt32) -> Bool {
        return true
    }

    func channel(_ channel: PTChannel, didRecieveFrame type: UInt32, tag: UInt32, payload: Data?) {
        guard let data = payload else { return }

        // Fast path: handle frameAck immediately on this thread (not main thread)
        // Main thread can be blocked during window dragging (NSEventTracking runloop mode),
        // which would delay ack processing and starve the flow control gate.
        if data.count >= MessageHeader.size {
            let typeRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            if typeRaw == MessageType.frameAck.rawValue {
                let payloadStart = MessageHeader.size
                let payload = data.subdata(in: payloadStart..<data.count)
                if let ack = FrameAckMessage.from(data: payload) {
                    acknowledgeFrame(ack.frameNumber)
                }
                return
            }
        }

        // All other messages (touch events, etc.) go through a serial background queue.
        // Avoids main thread which can be blocked during window dragging (NSEventTracking).
        receiveQueue.async { [weak self] in
            guard let self = self else { return }
            let deviceID = self.connectedDeviceID?.intValue ?? 0
            self.delegate?.usbDeviceManager(self, didReceive: data, fromDevice: deviceID)
        }
    }

    func channelDidEnd(_ channel: PTChannel, error: Error?) {
        log("USBDeviceManager: Channel ended. Error: \(String(describing: error))")

        if channel === peerChannel {
            let deviceID = connectedDeviceID?.intValue ?? 0
            let deviceIDNumber = connectedDeviceID
            peerChannel = nil
            connectedDeviceID = nil
            connectingDeviceID = nil

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.usbDeviceManager(self, didDisconnect: deviceID)
            }

            // Auto-reconnect after a short delay if we're still listening
            // This handles the case where iPad app restarts
            if isListening, let deviceIDNumber = deviceIDNumber {
                log("USBDeviceManager: Scheduling reconnection attempt...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self, self.isListening else { return }
                    // Only reconnect if we're not already connected
                    if self.peerChannel == nil && self.connectingDeviceID == nil {
                        self.log("USBDeviceManager: Attempting auto-reconnect to device \(deviceIDNumber)")
                        self.connectToDevice(deviceIDNumber)
                    }
                }
            }
        }
    }
}

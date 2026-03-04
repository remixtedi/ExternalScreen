import Foundation

/// Delegate for USB connection events on iOS
protocol USBConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: USBConnectionManager, didConnect port: UInt16)
    func connectionManager(_ manager: USBConnectionManager, didDisconnect error: Error?)
    func connectionManager(_ manager: USBConnectionManager, didReceive data: Data)
    func connectionManager(_ manager: USBConnectionManager, didFailWithError error: Error)
}

/// Manages USB connection from Mac using PeerTalk on iOS
/// iOS LISTENS on a port and Mac CONNECTS to it via PTUSBHub
final class USBConnectionManager: NSObject {

    // MARK: - Properties

    weak var delegate: USBConnectionManagerDelegate?

    private var serverChannel: PTChannel?
    private var peerChannel: PTChannel?
    private var isListening = false

    private let port: in_port_t
    private let frameType: UInt32 = 101

    // MARK: - Initialization

    init(port: UInt16 = ExternalScreenConstants.usbPort) {
        self.port = in_port_t(port)
        super.init()
    }

    // MARK: - Public Methods

    /// Starts listening for Mac connections
    func startListening() {
        guard !isListening else {
            print("USBConnectionManager: Already listening")
            return
        }

        print("USBConnectionManager: Starting to listen on port \(port)")
        print("USBConnectionManager: INADDR_LOOPBACK = \(INADDR_LOOPBACK)")

        let channel = PTChannel(protocol: nil, delegate: self)
        print("USBConnectionManager: PTChannel created, delegate = \(String(describing: channel.delegate))")

        channel.listen(on: port, IPv4Address: INADDR_LOOPBACK) { [weak self] error in
            guard let self = self else {
                print("USBConnectionManager: Listen callback - self is nil!")
                return
            }

            if let error = error {
                print("USBConnectionManager: *** Listen FAILED: \(error) ***")
                DispatchQueue.main.async {
                    self.delegate?.connectionManager(self, didFailWithError: error)
                }
            } else {
                print("USBConnectionManager: *** Listen SUCCESS on port \(self.port) ***")
                print("USBConnectionManager: Channel isListening = \(channel.isListening)")
            }
        }

        serverChannel = channel
        isListening = true
        print("USBConnectionManager: Server channel stored, waiting for Mac to connect...")
        print("USBConnectionManager: serverChannel.isListening = \(channel.isListening)")
    }

    /// Stops listening
    func stopListening() {
        print("USBConnectionManager: Stopping")

        peerChannel?.close()
        peerChannel = nil
        serverChannel?.close()
        serverChannel = nil

        isListening = false
    }

    /// Disconnects from the Mac
    func disconnect() {
        peerChannel?.close()
        peerChannel = nil
    }

    /// Sends data to the connected Mac
    @discardableResult
    func send(data: Data) -> Bool {
        guard let channel = peerChannel else {
            return false
        }

        channel.sendFrame(type: frameType, tag: 0, payload: data) { error in
            if let error = error {
                print("USBConnectionManager: Send error: \(error)")
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

    /// Sends a touch event to the Mac
    func sendTouch(type: MessageType, touch: TouchEventMessage) {
        sendMessage(type: type, payload: touch.toData())
    }

    /// Sends a frame acknowledgment
    func sendFrameAck(frameNumber: UInt32) {
        let ack = FrameAckMessage(
            frameNumber: frameNumber,
            receivedTime: currentTimestamp()
        )
        sendMessage(type: .frameAck, payload: ack.toData())
    }

    /// Whether currently connected to a Mac
    var connected: Bool {
        peerChannel != nil
    }

    // MARK: - Private Methods

    private func currentTimestamp() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}

// MARK: - PTChannelDelegate

extension USBConnectionManager: PTChannelDelegate {

    func channel(_ channel: PTChannel, shouldAcceptFrame type: UInt32, tag: UInt32, payloadSize: UInt32) -> Bool {
        return true
    }

    func channel(_ channel: PTChannel, didRecieveFrame type: UInt32, tag: UInt32, payload: Data?) {
        guard let data = payload else { return }

        print("USBConnectionManager: Received frame type=\(type) size=\(data.count)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.connectionManager(self, didReceive: data)
        }
    }

    func channelDidEnd(_ channel: PTChannel, error: Error?) {
        print("USBConnectionManager: Channel ended. Error: \(String(describing: error))")

        if channel === peerChannel {
            peerChannel = nil

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.connectionManager(self, didDisconnect: error)
            }
        }
    }

    func channel(_ channel: PTChannel, didAcceptConnection otherChannel: PTChannel, from address: PTAddress) {
        print("USBConnectionManager: *** Accepted connection from \(address.name):\(address.port) ***")

        // Close existing peer connection if any
        if let existingChannel = peerChannel {
            print("USBConnectionManager: Closing existing peer channel")
            existingChannel.close()
        }

        peerChannel = otherChannel
        peerChannel?.delegate = self
        print("USBConnectionManager: Peer channel set, delegate assigned")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("USBConnectionManager: Notifying delegate of connection")
            self.delegate?.connectionManager(self, didConnect: UInt16(self.port))
        }
    }
}

import Foundation

/// Message types for communication between macOS and iOS
public enum MessageType: UInt32 {
    case handshake = 0
    case displayConfig = 1
    case frameData = 2
    case frameAck = 3
    case touchBegan = 4
    case touchMoved = 5
    case touchEnded = 6
    case touchCancelled = 7
    case disconnect = 8
    case orientationChange = 9
    case displayCapabilities = 10
    case cursorPosition = 11
    case cursorImage = 12
}

/// Screen orientation sent from iPad to Mac
public enum ScreenOrientation: UInt8 {
    case landscape = 0
    case portrait = 1
}

/// Orientation change message sent from iPad to Mac
public struct OrientationMessage {
    public let orientation: ScreenOrientation

    public init(orientation: ScreenOrientation) {
        self.orientation = orientation
    }

    public static let size = 1

    public func toData() -> Data {
        var raw = orientation.rawValue
        return Data(bytes: &raw, count: 1)
    }

    public static func from(data: Data) -> OrientationMessage? {
        guard data.count >= size else { return nil }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt8.self) }
        guard let orientation = ScreenOrientation(rawValue: raw) else { return nil }
        return OrientationMessage(orientation: orientation)
    }
}

/// Header for all messages sent over USB
public struct MessageHeader {
    public let type: MessageType
    public let timestamp: UInt64
    public let payloadLength: UInt32

    public init(type: MessageType, timestamp: UInt64, payloadLength: UInt32) {
        self.type = type
        self.timestamp = timestamp
        self.payloadLength = payloadLength
    }

    public static let size = 16  // 4 + 8 + 4 bytes

    public func toData() -> Data {
        var data = Data(capacity: MessageHeader.size)
        var typeRaw = type.rawValue
        var ts = timestamp
        var len = payloadLength
        data.append(Data(bytes: &typeRaw, count: 4))
        data.append(Data(bytes: &ts, count: 8))
        data.append(Data(bytes: &len, count: 4))
        return data
    }

    public static func from(data: Data) -> MessageHeader? {
        guard data.count >= MessageHeader.size else { return nil }
        let typeRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let timestamp = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        let payloadLength = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
        guard let type = MessageType(rawValue: typeRaw) else { return nil }
        return MessageHeader(type: type, timestamp: timestamp, payloadLength: payloadLength)
    }
}

/// Handshake message for protocol version negotiation
public struct HandshakeMessage {
    public let protocolVersion: UInt32
    public let deviceName: String

    public init(protocolVersion: UInt32, deviceName: String) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
    }

    public func toData() -> Data {
        var data = Data()
        var version = protocolVersion
        data.append(Data(bytes: &version, count: 4))
        let nameData = deviceName.data(using: .utf8) ?? Data()
        var nameLen = UInt32(nameData.count)
        data.append(Data(bytes: &nameLen, count: 4))
        data.append(nameData)
        return data
    }

    public static func from(data: Data) -> HandshakeMessage? {
        guard data.count >= 8 else { return nil }
        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let nameLen = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard data.count >= 8 + Int(nameLen) else { return nil }
        let nameData = data.subdata(in: 8..<(8 + Int(nameLen)))
        let name = String(data: nameData, encoding: .utf8) ?? ""
        return HandshakeMessage(protocolVersion: version, deviceName: name)
    }
}

/// Display configuration sent from Mac to iPad
public struct DisplayConfigMessage {
    public let width: UInt32
    public let height: UInt32
    public let refreshRate: Float
    /// Clockwise rotation in degrees (0/90/180/270) the receiver applies when rendering.
    /// The stream's width/height above are already the rotated (e.g. portrait) dimensions;
    /// the receiver rotates the decoded frames back onto its physical panel.
    public let rotation: UInt32

    public init(width: UInt32, height: UInt32, refreshRate: Float, rotation: UInt32 = 0) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.rotation = rotation
    }

    public static let size = 16  // 4 + 4 + 4 + 4 bytes

    public func toData() -> Data {
        var data = Data(capacity: DisplayConfigMessage.size)
        var w = width
        var h = height
        var r = refreshRate
        var rot = rotation
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &r, count: 4))
        data.append(Data(bytes: &rot, count: 4))
        return data
    }

    public static func from(data: Data) -> DisplayConfigMessage? {
        // Accept the legacy 12-byte layout (no rotation field) so a pre-rotation
        // host can still drive a newer receiver; rotation defaults to 0.
        guard data.count >= 12 else { return nil }
        let width = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let height = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let refreshRate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Float.self) }
        let rotation: UInt32 = data.count >= DisplayConfigMessage.size
            ? data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
            : 0
        return DisplayConfigMessage(width: width, height: height, refreshRate: refreshRate, rotation: rotation)
    }
}

/// Frame data header (actual H264 data follows)
public struct FrameDataHeader {
    public let frameNumber: UInt32
    public let isKeyframe: Bool
    public let presentationTime: UInt64

    public init(frameNumber: UInt32, isKeyframe: Bool, presentationTime: UInt64) {
        self.frameNumber = frameNumber
        self.isKeyframe = isKeyframe
        self.presentationTime = presentationTime
    }

    public static let size = 13  // 4 + 1 + 8 bytes

    public func toData() -> Data {
        var data = Data(capacity: FrameDataHeader.size)
        var fn = frameNumber
        var keyframe: UInt8 = isKeyframe ? 1 : 0
        var pts = presentationTime
        data.append(Data(bytes: &fn, count: 4))
        data.append(Data(bytes: &keyframe, count: 1))
        data.append(Data(bytes: &pts, count: 8))
        return data
    }

    public static func from(data: Data) -> FrameDataHeader? {
        guard data.count >= FrameDataHeader.size else { return nil }
        let frameNumber = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let keyframeByte = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt8.self) }
        let presentationTime = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: UInt64.self) }
        return FrameDataHeader(frameNumber: frameNumber, isKeyframe: keyframeByte != 0, presentationTime: presentationTime)
    }
}

/// Touch event sent from iPad to Mac
public struct TouchEventMessage {
    public let touchId: UInt32
    public let x: Float  // Normalized 0.0 - 1.0
    public let y: Float  // Normalized 0.0 - 1.0
    public let pressure: Float

    public init(touchId: UInt32, x: Float, y: Float, pressure: Float = 1.0) {
        self.touchId = touchId
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    public static let size = 16  // 4 + 4 + 4 + 4 bytes

    public func toData() -> Data {
        var data = Data(capacity: TouchEventMessage.size)
        var id = touchId
        var xVal = x
        var yVal = y
        var pVal = pressure
        data.append(Data(bytes: &id, count: 4))
        data.append(Data(bytes: &xVal, count: 4))
        data.append(Data(bytes: &yVal, count: 4))
        data.append(Data(bytes: &pVal, count: 4))
        return data
    }

    public static func from(data: Data) -> TouchEventMessage? {
        guard data.count >= TouchEventMessage.size else { return nil }
        let touchId = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let x = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) }
        let y = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Float.self) }
        let pressure = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Float.self) }
        return TouchEventMessage(touchId: touchId, x: x, y: y, pressure: pressure)
    }
}

/// Frame acknowledgment for flow control
public struct FrameAckMessage {
    public let frameNumber: UInt32
    public let receivedTime: UInt64

    public init(frameNumber: UInt32, receivedTime: UInt64) {
        self.frameNumber = frameNumber
        self.receivedTime = receivedTime
    }

    public static let size = 12  // 4 + 8 bytes

    public func toData() -> Data {
        var data = Data(capacity: FrameAckMessage.size)
        var fn = frameNumber
        var rt = receivedTime
        data.append(Data(bytes: &fn, count: 4))
        data.append(Data(bytes: &rt, count: 8))
        return data
    }

    public static func from(data: Data) -> FrameAckMessage? {
        guard data.count >= FrameAckMessage.size else { return nil }
        let frameNumber = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let receivedTime = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        return FrameAckMessage(frameNumber: frameNumber, receivedTime: receivedTime)
    }
}

/// Receiver's native display capabilities sent from Mac receiver to host
public struct DisplayCapabilitiesMessage {
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let scale: Float

    public init(pixelWidth: UInt32, pixelHeight: UInt32, scale: Float) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    public static let size = 12  // 4 + 4 + 4 bytes

    public func toData() -> Data {
        var data = Data(capacity: DisplayCapabilitiesMessage.size)
        var w = pixelWidth
        var h = pixelHeight
        var s = scale
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(Data(bytes: &s, count: 4))
        return data
    }

    public static func from(data: Data) -> DisplayCapabilitiesMessage? {
        guard data.count >= DisplayCapabilitiesMessage.size else { return nil }
        let w = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let h = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let s = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Float.self) }
        return DisplayCapabilitiesMessage(pixelWidth: w, pixelHeight: h, scale: s)
    }
}

/// Cursor position sent from host to Mac receiver (normalized 0.0-1.0)
public struct CursorPositionMessage {
    public let x: Float
    public let y: Float
    public let visible: Bool

    public init(x: Float, y: Float, visible: Bool) {
        self.x = x
        self.y = y
        self.visible = visible
    }

    public static let size = 9  // 4 + 4 + 1 bytes

    public func toData() -> Data {
        var data = Data(capacity: CursorPositionMessage.size)
        var xv = x
        var yv = y
        var v: UInt8 = visible ? 1 : 0
        data.append(Data(bytes: &xv, count: 4))
        data.append(Data(bytes: &yv, count: 4))
        data.append(Data(bytes: &v, count: 1))
        return data
    }

    public static func from(data: Data) -> CursorPositionMessage? {
        guard data.count >= CursorPositionMessage.size else { return nil }
        let x = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float.self) }
        let y = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt8.self) }
        return CursorPositionMessage(x: x, y: y, visible: v != 0)
    }
}

/// Cursor image (PNG) sent from host to Mac receiver when the cursor changes.
/// Hotspot is in image pixel coordinates.
public struct CursorImageMessage {
    public let hotspotX: Float
    public let hotspotY: Float
    public let pngData: Data

    public init(hotspotX: Float, hotspotY: Float, pngData: Data) {
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pngData = pngData
    }

    public static let headerSize = 12  // 4 + 4 + 4 bytes

    public func toData() -> Data {
        var data = Data(capacity: CursorImageMessage.headerSize + pngData.count)
        var hx = hotspotX
        var hy = hotspotY
        var len = UInt32(pngData.count)
        data.append(Data(bytes: &hx, count: 4))
        data.append(Data(bytes: &hy, count: 4))
        data.append(Data(bytes: &len, count: 4))
        data.append(pngData)
        return data
    }

    public static func from(data: Data) -> CursorImageMessage? {
        guard data.count >= CursorImageMessage.headerSize else { return nil }
        let hx = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Float.self) }
        let hy = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) }
        let len = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        guard data.count >= CursorImageMessage.headerSize + Int(len) else { return nil }
        let png = data.subdata(in: CursorImageMessage.headerSize..<(CursorImageMessage.headerSize + Int(len)))
        return CursorImageMessage(hotspotX: hx, hotspotY: hy, pngData: png)
    }
}

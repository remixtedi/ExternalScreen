import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import IOSurface

/// Delegate for receiving captured frames
protocol ScreenCaptureManagerDelegate: AnyObject {
    func screenCaptureManager(_ manager: ScreenCaptureManager, didCapture sampleBuffer: CMSampleBuffer)
    func screenCaptureManager(_ manager: ScreenCaptureManager, didCapture pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    func screenCaptureManager(_ manager: ScreenCaptureManager, didFailWithError error: Error)
}

/// Manages screen capture using ScreenCaptureKit
@available(macOS 14.0, *)
final class ScreenCaptureManager: NSObject {

    // MARK: - Properties

    weak var delegate: ScreenCaptureManagerDelegate?

    private var stream: SCStream?
    private var targetDisplayID: CGDirectDisplayID = 0
    private var isCapturing = false

    private let width: Int
    private let height: Int
    private let frameRate: Int

    // MARK: - Initialization

    init(preset: DisplayPreset = ExternalScreenConstants.defaultPreset,
         frameRate: Int = Int(ExternalScreenConstants.defaultRefreshRate)) {
        self.width = preset.width
        self.height = preset.height
        self.frameRate = frameRate
        super.init()
    }

    init(width: Int, height: Int, frameRate: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        super.init()
    }

    // MARK: - Public Methods

    /// Starts capturing from the specified display
    /// - Parameter displayID: The CGDirectDisplayID to capture
    func startCapture(displayID: CGDirectDisplayID) async throws {
        guard !isCapturing else {
            print("ScreenCaptureManager: Already capturing")
            return
        }

        self.targetDisplayID = displayID
        print("ScreenCaptureManager: Starting capture for display \(displayID)")

        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find our target display
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound(displayID)
        }

        print("ScreenCaptureManager: Found display \(display.width)x\(display.height)")

        // Create content filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream with high quality settings
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = ExternalScreenConstants.captureQueueDepth
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false

        // High quality scaling settings for sharp text
        configuration.scalesToFit = true  // Scale to fill output dimensions
        configuration.preservesAspectRatio = true  // Maintain aspect ratio

        // Use high quality color space for better color accuracy
        configuration.colorSpaceName = CGColorSpace.sRGB

        print("ScreenCaptureManager: Configured capture \(width)x\(height) @ \(frameRate)fps")

        // Create stream
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream

        // Add output handler
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.externalscreen.screencapture"))

        // Start capture
        try await stream.startCapture()
        isCapturing = true
        print("ScreenCaptureManager: Capture started")
    }

    /// Stops the current capture session
    func stopCapture() async {
        guard isCapturing, let stream = stream else { return }

        print("ScreenCaptureManager: Stopping capture")

        do {
            try await stream.stopCapture()
        } catch {
            print("ScreenCaptureManager: Error stopping capture: \(error)")
        }

        self.stream = nil
        isCapturing = false
    }

    /// Updates the capture configuration
    func updateConfiguration(width: Int, height: Int, frameRate: Int) async throws {
        guard let stream = stream else { return }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = ExternalScreenConstants.captureQueueDepth
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true

        try await stream.updateConfiguration(configuration)
    }

    /// Updates the capture configuration using a preset
    func updateConfiguration(preset: DisplayPreset, frameRate: Int) async throws {
        try await updateConfiguration(width: preset.width, height: preset.height, frameRate: frameRate)
    }
}

// MARK: - SCStreamDelegate

@available(macOS 14.0, *)
extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureManager: Stream stopped with error: \(error)")
        isCapturing = false
        delegate?.screenCaptureManager(self, didFailWithError: error)
    }
}

// MARK: - SCStreamOutput

@available(macOS 14.0, *)
extension ScreenCaptureManager: SCStreamOutput {
    private static var frameCount = 0
    private static var lastLogTime: Date = Date()
    private static var successCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // Check if frame is valid
        guard sampleBuffer.isValid else { return }

        Self.frameCount += 1

        // Log periodically
        let now = Date()
        if now.timeIntervalSince(Self.lastLogTime) >= 2.0 {
            print("ScreenCaptureManager: Received \(Self.frameCount) frames, \(Self.successCount) encoded in last 2 seconds")
            Self.frameCount = 0
            Self.successCount = 0
            Self.lastLogTime = now
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Try to get image buffer directly first
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            Self.successCount += 1
            delegate?.screenCaptureManager(self, didCapture: sampleBuffer)
            return
        }

        // Try to get IOSurface from attachments and create pixel buffer
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) {
            let attachments = attachmentsArray as NSArray
            if attachments.count > 0, let dict = attachments[0] as? NSDictionary {
                // Check frame status
                if let statusRaw = dict[SCStreamFrameInfo.status] as? Int, statusRaw != 1 {
                    // Not complete, skip
                    return
                }

                // Log format and attachment info for debugging
                if Self.frameCount == 1 {
                    if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                        let mediaType = CMFormatDescriptionGetMediaType(formatDesc)
                        let subType = CMFormatDescriptionGetMediaSubType(formatDesc)
                        print("ScreenCaptureManager: Format mediaType: \(mediaType), mediaSubType: \(subType)")
                    } else {
                        print("ScreenCaptureManager: No format description")
                    }
                    print("ScreenCaptureManager: Attachment keys: \(dict.allKeys)")

                    // Check for data buffer
                    if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                        var length: Int = 0
                        CMBlockBufferGetDataLength(dataBuffer)
                        print("ScreenCaptureManager: Has data buffer, length: \(CMBlockBufferGetDataLength(dataBuffer))")
                    } else {
                        print("ScreenCaptureManager: No data buffer")
                    }
                }
            }
        }
    }
}

// MARK: - Errors

enum ScreenCaptureError: LocalizedError {
    case displayNotFound(CGDirectDisplayID)
    case permissionDenied
    case streamCreationFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound(let id):
            return "Display with ID \(id) not found"
        case .permissionDenied:
            return "Screen recording permission denied"
        case .streamCreationFailed:
            return "Failed to create capture stream"
        }
    }
}

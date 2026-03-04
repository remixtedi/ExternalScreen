import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Delegate for receiving encoded video data
protocol H264EncoderDelegate: AnyObject {
    func h264Encoder(_ encoder: H264Encoder, didEncode data: Data, isKeyframe: Bool, presentationTime: CMTime)
    func h264Encoder(_ encoder: H264Encoder, didFailWithError error: Error)
}

/// H264 hardware encoder using VideoToolbox
final class H264Encoder {

    // MARK: - Properties

    weak var delegate: H264EncoderDelegate?

    private var compressionSession: VTCompressionSession?
    private var isEncoding = false
    private var frameCount: Int64 = 0

    private let width: Int
    private let height: Int
    private let frameRate: Int
    private let bitrate: Int
    private let keyframeInterval: Int

    private let callbackQueue = DispatchQueue(label: "com.externalscreen.encoder.callback")

    // MARK: - Initialization

    init(preset: DisplayPreset = ExternalScreenConstants.defaultPreset,
         frameRate: Int = Int(ExternalScreenConstants.defaultRefreshRate),
         keyframeInterval: Int = ExternalScreenConstants.keyframeInterval) {
        self.width = preset.width
        self.height = preset.height
        self.frameRate = frameRate
        self.bitrate = preset.recommendedBitrate
        self.keyframeInterval = keyframeInterval
    }

    init(width: Int, height: Int, frameRate: Int, bitrate: Int, keyframeInterval: Int) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Starts the encoder
    func start() throws {
        guard !isEncoding else { return }

        print("H264Encoder: Starting encoder \(width)x\(height) @ \(frameRate)fps, \(bitrate/1_000_000)Mbps")

        // Use low-latency encoder specification
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: false
        ]

        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw H264EncoderError.sessionCreationFailed(status)
        }

        compressionSession = session

        // Configure session properties
        try configureSession(session)

        // Prepare to encode
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw H264EncoderError.prepareFailed(prepareStatus)
        }

        isEncoding = true
        frameCount = 0
        print("H264Encoder: Encoder started successfully")
    }

    /// Stops the encoder
    func stop() {
        guard isEncoding, let session = compressionSession else { return }

        print("H264Encoder: Stopping encoder")

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
        isEncoding = false
        frameCount = 0  // Reset frame count for clean restart
    }

    /// Encodes a sample buffer containing a video frame
    /// - Parameter sampleBuffer: The CMSampleBuffer from ScreenCaptureKit
    func encode(sampleBuffer: CMSampleBuffer) {
        guard isEncoding, let session = compressionSession else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("H264Encoder: Failed to get pixel buffer from sample buffer")
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        // Force keyframe at interval
        var properties: [CFString: Any]? = nil
        if frameCount % Int64(keyframeInterval) == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        }

        var infoFlags = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties as CFDictionary?,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
        }

        if status != noErr {
            print("H264Encoder: Encode failed with status \(status)")
        }

        frameCount += 1
    }

    /// Encodes a pixel buffer directly
    /// - Parameters:
    ///   - pixelBuffer: The CVPixelBuffer to encode
    ///   - presentationTime: The presentation timestamp
    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard isEncoding, let session = compressionSession else { return }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        var properties: [CFString: Any]? = nil
        if frameCount % Int64(keyframeInterval) == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        }

        var infoFlags = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: properties as CFDictionary?,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, infoFlags, sampleBuffer in
            self?.handleEncodedFrame(status: status, sampleBuffer: sampleBuffer)
        }

        if status != noErr {
            print("H264Encoder: Encode failed with status \(status)")
        }

        frameCount += 1
    }

    /// Forces a keyframe on the next encode
    func forceKeyframe() {
        frameCount = 0  // Will trigger keyframe on next encode
    }

    // MARK: - Private Methods

    private func configureSession(_ session: VTCompressionSession) throws {
        var status: OSStatus

        // Real-time encoding
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if status != noErr { print("H264Encoder: Warning - failed to set RealTime: \(status)") }

        // Bitrate - use average bitrate
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        if status != noErr { print("H264Encoder: Warning - failed to set bitrate: \(status)") }

        // Data rate limits - allow bursts up to 1.5x bitrate for better quality on complex scenes
        // Format: [bytes per second, duration in seconds]
        let dataRateLimits: [Int] = [bitrate * 3 / 2, 1]
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)
        if status != noErr { print("H264Encoder: Warning - failed to set data rate limits: \(status)") }

        // Frame rate
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        if status != noErr { print("H264Encoder: Warning - failed to set frame rate: \(status)") }

        // Keyframe interval
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        if status != noErr { print("H264Encoder: Warning - failed to set keyframe interval: \(status)") }

        // Profile level - High profile for better quality (better compression efficiency)
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        if status != noErr { print("H264Encoder: Warning - failed to set profile: \(status)") }

        // Allow frame reordering (false for lowest latency)
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if status != noErr { print("H264Encoder: Warning - failed to disable frame reordering: \(status)") }

        // Maximum frame delay count
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        if status != noErr { print("H264Encoder: Warning - failed to set max frame delay: \(status)") }

        // Quality setting - at 60fps encoder has more time per frame, bias toward sharpness
        // Values range from 0.0 (max compression) to 1.0 (max quality)
        status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.7 as CFNumber)
        if status != noErr { print("H264Encoder: Warning - failed to set quality: \(status)") }
    }

    private func handleEncodedFrame(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            let error = H264EncoderError.encodeFailed(status)
            callbackQueue.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.h264Encoder(self, didFailWithError: error)
            }
            return
        }

        guard let sampleBuffer = sampleBuffer else { return }

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = false
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if let dependsOnOthers = CFDictionaryGetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque()) {
                isKeyframe = !CFBooleanGetValue(unsafeBitCast(dependsOnOthers, to: CFBoolean.self))
            }
        }

        // Get presentation time
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Extract NAL units
        guard let data = extractNALUnits(from: sampleBuffer, isKeyframe: isKeyframe) else {
            return
        }

        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.h264Encoder(self, didEncode: data, isKeyframe: isKeyframe, presentationTime: presentationTime)
        }
    }

    private func extractNALUnits(from sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        var data = Data()

        // If keyframe, prepend SPS and PPS
        if isKeyframe {
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get SPS
                var spsSize: Int = 0
                var spsCount: Int = 0
                var spsPointer: UnsafePointer<UInt8>?

                let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPointer,
                    parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount,
                    nalUnitHeaderLengthOut: nil
                )

                if spsStatus == noErr, let spsPointer = spsPointer {
                    // Add start code + SPS
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(spsPointer, count: spsSize)
                }

                // Get PPS
                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?

                let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPointer,
                    parameterSetSizeOut: &ppsSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )

                if ppsStatus == noErr, let ppsPointer = ppsPointer {
                    // Add start code + PPS
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(ppsPointer, count: ppsSize)
                }
            }
        }

        // Get data buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else {
            return nil
        }

        // Convert AVCC to Annex-B format
        var offset = 0
        let headerLength = 4  // AVCC uses 4-byte length prefix

        while offset < totalLength - headerLength {
            // Read NAL unit length (big-endian)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)

            offset += headerLength

            if offset + Int(nalLength) > totalLength {
                break
            }

            // Add start code
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

            // Add NAL unit data
            data.append(Data(bytes: dataPointer + offset, count: Int(nalLength)))

            offset += Int(nalLength)
        }

        return data.isEmpty ? nil : data
    }
}

// MARK: - Errors

enum H264EncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case prepareFailed(OSStatus)
    case encodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create compression session: \(status)"
        case .prepareFailed(let status):
            return "Failed to prepare encoder: \(status)"
        case .encodeFailed(let status):
            return "Encoding failed: \(status)"
        }
    }
}

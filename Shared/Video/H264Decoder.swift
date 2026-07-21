import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Delegate for receiving decoded video frames
protocol H264DecoderDelegate: AnyObject {
    func h264Decoder(_ decoder: H264Decoder, didDecode pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
    func h264Decoder(_ decoder: H264Decoder, didFailWithError error: Error)
}

/// H264 hardware decoder using VideoToolbox
final class H264Decoder {

    // MARK: - Properties

    weak var delegate: H264DecoderDelegate?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    private var sps: Data?
    private var pps: Data?

    /// Frame rate for timing calculations (default 120 Hz for iPad Pro)
    private var frameRate: Int32 = 120

    private let callbackQueue = DispatchQueue(label: "com.externalscreen.decoder.callback")

    /// Flag to track if decoder is active (prevents callbacks after reset)
    private var isActive = false
    private let stateLock = NSLock()

    // MARK: - Initialization

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Decodes H264 NAL units
    /// - Parameters:
    ///   - data: The encoded H264 data in Annex-B format
    ///   - presentationTime: The presentation timestamp
    func decode(data: Data, presentationTime: UInt64) {
        // Parse NAL units from Annex-B format
        let nalUnits = parseNALUnits(from: data)

        if nalUnits.isEmpty {
            print("H264Decoder: No NAL units found in \(data.count) bytes")
            // Print first few bytes for debugging
            let preview = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("H264Decoder: Data preview: \(preview)")
            return
        }

        for nalUnit in nalUnits {
            guard !nalUnit.isEmpty else { continue }

            let nalType = nalUnit[0] & 0x1F

            switch nalType {
            case 7:  // SPS
                print("H264Decoder: Received SPS (\(nalUnit.count) bytes)")
                sps = nalUnit
                tryCreateDecoder()

            case 8:  // PPS
                print("H264Decoder: Received PPS (\(nalUnit.count) bytes)")
                pps = nalUnit
                tryCreateDecoder()

            case 5:  // IDR (keyframe)
                print("H264Decoder: Received IDR frame (\(nalUnit.count) bytes), session=\(decompressionSession != nil)")
                decodeNALUnit(nalUnit, presentationTime: presentationTime, isKeyframe: true)

            case 1:  // Non-IDR
                decodeNALUnit(nalUnit, presentationTime: presentationTime, isKeyframe: false)

            default:
                print("H264Decoder: Received NAL type \(nalType) (\(nalUnit.count) bytes)")
            }
        }
    }

    /// Stops the decoder and releases resources
    func stop() {
        stateLock.lock()
        isActive = false
        stateLock.unlock()

        if let session = decompressionSession {
            // Wait for pending frames to complete before invalidating
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        sps = nil
        pps = nil
    }

    /// Resets the decoder state (call when seeking or after errors)
    func reset() {
        stop()
    }

    /// Sets the target frame rate for timing calculations
    /// - Parameter rate: The frame rate in Hz (e.g., 120 for 120Hz display)
    func setFrameRate(_ rate: Int) {
        frameRate = Int32(rate)
        print("H264Decoder: Frame rate set to \(rate) Hz")
    }

    // MARK: - Private Methods

    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var offset = 0

        while offset < data.count - 4 {
            // Look for start code (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
            var startCodeLength = 0

            if data[offset] == 0x00 && data[offset + 1] == 0x00 {
                if data[offset + 2] == 0x00 && data[offset + 3] == 0x01 {
                    startCodeLength = 4
                } else if data[offset + 2] == 0x01 {
                    startCodeLength = 3
                }
            }

            if startCodeLength > 0 {
                let nalStart = offset + startCodeLength

                // Find next start code or end
                var nalEnd = data.count
                for i in nalStart..<(data.count - 3) {
                    if data[i] == 0x00 && data[i + 1] == 0x00 {
                        if (data[i + 2] == 0x00 && i + 3 < data.count && data[i + 3] == 0x01) ||
                           data[i + 2] == 0x01 {
                            nalEnd = i
                            break
                        }
                    }
                }

                if nalEnd > nalStart {
                    nalUnits.append(data.subdata(in: nalStart..<nalEnd))
                }

                offset = nalEnd
            } else {
                offset += 1
            }
        }

        return nalUnits
    }

    private func tryCreateDecoder() {
        guard let sps = sps, let pps = pps else {
            print("H264Decoder: tryCreateDecoder - waiting for SPS=\(self.sps != nil) PPS=\(self.pps != nil)")
            return
        }
        guard decompressionSession == nil else {
            print("H264Decoder: tryCreateDecoder - session already exists")
            return
        }

        print("H264Decoder: Creating decoder with SPS(\(sps.count) bytes) and PPS(\(pps.count) bytes)")

        // Create format description from SPS and PPS
        var formatDescription: CMVideoFormatDescription?

        var status: OSStatus = noErr
        sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                let parameterSets: [UnsafePointer<UInt8>] = [
                    spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let parameterSetSizes: [Int] = [sps.count, pps.count]

                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSets,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }

        guard status == noErr, let formatDescription = formatDescription else {
            print("H264Decoder: Failed to create format description: \(status)")
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        print("H264Decoder: Format description created: \(dimensions.width)x\(dimensions.height)")

        self.formatDescription = formatDescription

        // Create decompression session
        createDecompressionSession(formatDescription: formatDescription)
    }

    private func createDecompressionSession(formatDescription: CMVideoFormatDescription) {
        // Destination pixel buffer attributes
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        // Callback for decoded frames
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, presentationTimeStamp, _ in
                guard let refcon = refcon else { return }
                let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.handleDecodedFrame(status: status, imageBuffer: imageBuffer, presentationTime: presentationTimeStamp)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("H264Decoder: Failed to create decompression session: \(status)")
            return
        }

        // Configure for low latency
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        decompressionSession = session

        stateLock.lock()
        isActive = true
        stateLock.unlock()

        print("H264Decoder: Decompression session created")
    }

    private func decodeNALUnit(_ nalUnit: Data, presentationTime: UInt64, isKeyframe: Bool) {
        guard let session = decompressionSession, let formatDescription = formatDescription else {
            // If we don't have a session yet, wait for SPS/PPS
            if isKeyframe {
                print("H264Decoder: Waiting for SPS/PPS")
            }
            return
        }

        // Convert NAL unit to AVCC format (length prefix instead of start code)
        var avccData = Data()
        var length = CFSwapInt32HostToBig(UInt32(nalUnit.count))
        avccData.append(Data(bytes: &length, count: 4))
        avccData.append(nalUnit)

        // Create block buffer - use CMBlockBufferCreateWithMemoryBlock with copy
        var blockBuffer: CMBlockBuffer?
        let dataLength = avccData.count

        // First create an empty block buffer
        var status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, var blockBuffer = blockBuffer else {
            print("H264Decoder: Failed to create empty block buffer: \(status)")
            return
        }

        // Then append the data with a copy
        status = avccData.withUnsafeBytes { pointer in
            CMBlockBufferAppendMemoryBlock(
                blockBuffer,
                memoryBlock: nil,  // Will allocate
                length: dataLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: 0
            )
        }

        if status != noErr {
            print("H264Decoder: Failed to append to block buffer: \(status)")
            return
        }

        // Copy the actual data
        status = avccData.withUnsafeBytes { pointer in
            CMBlockBufferReplaceDataBytes(
                with: pointer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }

        if status != noErr {
            print("H264Decoder: Failed to copy data to block buffer: \(status)")
            return
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frameRate),
            presentationTimeStamp: CMTime(value: CMTimeValue(presentationTime), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            print("H264Decoder: Failed to create sample buffer: \(sampleStatus)")
            return
        }

        // Decode
        var infoFlags = VTDecodeInfoFlags()
        let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        if decodeStatus != noErr {
            print("H264Decoder: Decode failed: \(decodeStatus)")
        }
    }

    private static var decodedCount = 0

    private func handleDecodedFrame(status: OSStatus, imageBuffer: CVImageBuffer?, presentationTime: CMTime) {
        // Check if decoder is still active (prevents processing after reset)
        stateLock.lock()
        let active = isActive
        stateLock.unlock()

        guard active else {
            // Decoder was reset, ignore this callback
            return
        }

        guard status == noErr else {
            print("H264Decoder: Decode callback error: \(status)")
            let error = H264DecoderError.decodeFailed(status)
            callbackQueue.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.h264Decoder(self, didFailWithError: error)
            }
            return
        }

        guard let pixelBuffer = imageBuffer else {
            print("H264Decoder: Decode callback - no pixel buffer")
            return
        }

        Self.decodedCount += 1
        if Self.decodedCount % 30 == 1 {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("H264Decoder: Successfully decoded frame \(Self.decodedCount) - \(width)x\(height)")
        }

        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            // Double-check active state in async callback
            self.stateLock.lock()
            let stillActive = self.isActive
            self.stateLock.unlock()
            guard stillActive else { return }

            self.delegate?.h264Decoder(self, didDecode: pixelBuffer, presentationTime: presentationTime)
        }
    }
}

// MARK: - Errors

enum H264DecoderError: LocalizedError {
    case decodeFailed(OSStatus)
    case formatDescriptionFailed

    var errorDescription: String? {
        switch self {
        case .decodeFailed(let status):
            return "Decoding failed with status: \(status)"
        case .formatDescriptionFailed:
            return "Failed to create format description"
        }
    }
}

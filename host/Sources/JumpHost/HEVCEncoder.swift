import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox
import WebRTC

/// Hardware HEVC (H.265) encoder for WebRTC.
///
/// The prebuilt macOS WebRTC framework has the H.265 RTP packetizer but no Objective-C HEVC
/// encoder, so this wraps VideoToolbox directly. Output is Annex B with VPS/SPS/PPS ahead of
/// every keyframe, which is what the RFC 7798 packetizer expects.
final class HEVCEncoder: NSObject, RTCVideoEncoder {
    static let codecName = "H265"
    static var codecInfo: RTCVideoCodecInfo {
        RTCVideoCodecInfo(name: codecName, parameters: [
            "profile-id": "1", "tier-flag": "0", "level-id": "180", "tx-mode": "SRST",
        ])
    }

    private var callback: RTCVideoEncoderCallback?
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var bitrateKbps: UInt32 = 0
    private var framerate: UInt32 = 60
    private var scalePool: CVPixelBufferPool?
    private var scaleTemp: [UInt8] = []
    private var transfer: VTPixelTransferSession?
    private let lock = NSLock()

    // WebRTC can only lower the resolution under a weak connection when the encoder reports QP,
    // which this one doesn't; without that it keeps the full size and drops frames instead
    // (choppy). So the encoder steps its own output size down with the bitrate WebRTC allows,
    // and back up once the connection has stayed good for a while.
    private var baseWidth: Int32 = 0
    private var baseHeight: Int32 = 0
    private var tier = 0
    private static let tierScales: [Double] = [1.0, 0.75, 0.625, 0.5]
    /// Bitrate (kbps, for a 2560x1664 stream) each size needs; scaled by the stream's pixel count.
    private static let tierNeedsKbps: [Double] = [9_000, 5_000, 2_800, 0]
    private var lowSince: CFTimeInterval?
    private var highSince: CFTimeInterval?
    private var startedAt: CFTimeInterval = 0

    // MARK: RTCVideoEncoder

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        self.callback = callback
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        baseWidth = Int32(settings.width)
        baseHeight = Int32(settings.height)
        bitrateKbps = settings.startBitrate
        framerate = max(settings.maxFramerate, 1)
        tier = 0
        lowSince = nil
        highSince = nil
        startedAt = CACurrentMediaTime()
        applyTierSize()
        return makeSession() ? 0 : -1
    }

    func release() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        return 0
    }

    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        lock.lock()
        if updateTier(now: CACurrentMediaTime()) {
            applyTierSize()
            if !makeSession() {
                lock.unlock()
                return -1
            }
        }
        let session = self.session
        let width = self.width
        let height = self.height
        let pixelBuffer = session == nil ? nil : pixelBuffer(for: frame)
        lock.unlock()
        guard let session, let pixelBuffer else { return -1 }

        let forceKey = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let rtpTimestamp = frame.timeStamp
        let rotation = frame.rotation
        let captureMs = frame.timeStampNs / 1_000_000
        let encodeStartMs = Int64(CACurrentMediaTime() * 1000)

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample, let (data, isKey) = Self.annexB(sample) else { return }
            let image = RTCEncodedImage()
            image.buffer = data
            image.encodedWidth = width
            image.encodedHeight = height
            image.timeStamp = UInt32(bitPattern: rtpTimestamp)
            image.captureTimeMs = captureMs
            image.encodeStartMs = encodeStartMs
            image.encodeFinishMs = Int64(CACurrentMediaTime() * 1000)
            image.frameType = isKey ? .videoFrameKey : .videoFrameDelta
            image.rotation = rotation
            image.contentType = .screenshare
            image.qp = NSNumber(value: -1)
            _ = self.callback?(image, HEVCCodecSpecificInfo())
        }
        return status == noErr ? 0 : -1
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        bitrateKbps = bitrateKbit
        self.framerate = max(framerate, 1)
        if let session { applyRates(session) }
        return 0
    }

    func implementationName() -> String { "VideoToolbox HEVC" }

    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }

    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }

    // MARK: Private (called with `lock` held)

    /// Moves `tier` toward what the bitrate supports: down after 1.5 s below what the current size
    /// needs (at once when far below), up one step after 6 s comfortably above the next size's need.
    /// True when the size changed.
    private func updateTier(now: CFTimeInterval) -> Bool {
        let pixels = Double(baseWidth) * Double(baseHeight)
        let factor = max(pixels / (2560.0 * 1664.0), 0.1)
        func needs(_ tier: Int) -> Double { Self.tierNeedsKbps[tier] * factor }
        let kbps = Double(bitrateKbps)

        if tier < Self.tierScales.count - 1, kbps < needs(tier) {
            highSince = nil
            // The estimate starts low and ramps up for the first seconds: don't shrink for that.
            guard now - startedAt >= 3 else { return false }
            let since = lowSince ?? now
            lowSince = since
            guard now - since >= 1.5 || kbps < needs(tier) * 0.6 else { return false }
            var next = tier
            while next < Self.tierScales.count - 1, kbps < needs(next) { next += 1 }
            tier = next
            lowSince = nil
            return true
        }
        lowSince = nil
        if tier > 0, kbps >= needs(tier - 1) * 1.3 {
            let since = highSince ?? now
            highSince = since
            guard now - since >= 6 else { return false }
            tier -= 1
            highSince = nil
            return true
        }
        highSince = nil
        return false
    }

    private func applyTierSize() {
        let scale = Self.tierScales[tier]
        width = max(Int32(Double(baseWidth) * scale) & ~1, 2)
        height = max(Int32(Double(baseHeight) * scale) & ~1, 2)
        scalePool = nil
        hostLog("[hevc] \(bitrateKbps) kbps: sending \(width)x\(height)")
    }

    private func makeSession() -> Bool {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        // Low-latency rate control where the hardware offers it for HEVC; plain realtime otherwise.
        let specifications: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
             kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true],
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
        ]
        var created: VTCompressionSession?
        for specification in specifications {
            let status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr, created != nil { break }
            created = nil
        }
        guard let session = created else {
            hostLog("[hevc] could not create a \(width)x\(height) HEVC session")
            return false
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Keyframes only when WebRTC asks (new viewer, loss); the idle refresh keeps quality up.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7200 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 240 as CFNumber)
        applyRates(session)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        hostLog("[hevc] encoding \(width)x\(height)")
        return true
    }

    private func applyRates(_ session: VTCompressionSession) {
        let bitsPerSecond = max(Int(bitrateKbps) * 1000, 300_000)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
        // Allow short bursts (a scroll, a new window) without overshooting for long.
        let limits = [Double(bitsPerSecond) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: framerate as CFNumber)
    }

    /// The capture's NV12 buffer as-is, or cropped/scaled to what WebRTC adapted the stream to.
    private func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let w = Int32(width), h = Int32(height)
        if !buffer.requiresCropping() && !buffer.requiresScaling(toWidth: w, height: h) {
            return buffer.pixelBuffer
        }
        if scalePool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &scalePool)
        }
        guard let scalePool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, scalePool, &output)
        guard let output else { return nil }
        // Plain downscaling (the size steps above): in hardware, not on the CPU.
        if !buffer.requiresCropping() {
            if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
            if let transfer, VTPixelTransferSessionTransferImage(transfer, from: buffer.pixelBuffer, to: output) == noErr {
                return output
            }
        }
        let tempSize = Int(buffer.bufferSizeForCroppingAndScaling(toWidth: w, height: h))
        if scaleTemp.count < tempSize { scaleTemp = [UInt8](repeating: 0, count: tempSize) }
        let ok = scaleTemp.withUnsafeMutableBufferPointer { buffer.cropAndScale(to: output, withTempBuffer: $0.baseAddress) }
        return ok ? output : nil
    }

    /// Length-prefixed HEVC (HVCC) -> Annex B, with parameter sets in front of keyframes.
    private static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()

        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return out.isEmpty ? nil : (out, isKey)
    }
}

/// WebRTC wants codec-specific info with each frame; HEVC needs none beyond the payload type.
final class HEVCCodecSpecificInfo: NSObject, RTCCodecSpecificInfo {}

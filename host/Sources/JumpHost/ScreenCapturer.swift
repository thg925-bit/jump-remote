import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit
import WebRTC

/// Captures one display with ScreenCaptureKit and feeds NV12 frames into a WebRTC video source.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Started {
        let displayID: CGDirectDisplayID
        /// Display size in points (what input coordinates map onto).
        let pointSize: CGSize
        /// Streamed frame size in pixels.
        let pixelSize: CGSize
    }

    var onStop: ((Error?) -> Void)?
    /// System audio as 48 kHz stereo Int16 little-endian interleaved PCM, on the audio queue.
    /// Set before `start` to capture audio at all.
    var onAudio: ((Data) -> Void)?

    private let rtcCapturer: RTCVideoCapturer
    // Strong on purpose: the track only keeps the native source alive, not this ObjC
    // wrapper, and frames pushed into a deallocated wrapper vanish silently.
    private let sink: RTCVideoSource
    private var deliveredFrames = 0
    private let outputQueue = DispatchQueue(label: "jump.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "jump.capture.audio", qos: .userInteractive)
    private var stream: SCStream?

    // ScreenCaptureKit only emits frames when pixels change. Re-sending the last frame while
    // the screen is idle lets the encoder refine a static image to full quality.
    private var lastBuffer: CVPixelBuffer?
    private var lastDelivery: CFTimeInterval = 0
    private var refreshTimer: DispatchSourceTimer?
    private static let idleRefreshInterval: CFTimeInterval = 0.2

    init(source: RTCVideoSource) {
        self.rtcCapturer = RTCVideoCapturer(delegate: source)
        self.sink = source
        super.init()
    }

    func start(displayID: CGDirectDisplayID, maxLongEdge: Int?, showsCursor: Bool) async throws -> Started {
        // A display that has just appeared (a virtual one, a monitor plugged in) can take a
        // moment to show up here: look a few times before settling for another one.
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<5 where !content.displays.contains(where: { $0.displayID == displayID }) {
            try await Task.sleep(nanoseconds: 200_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "JumpHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "캡처할 디스플레이가 없습니다"])
        }
        if display.displayID != displayID { hostLog("[capture] display \(displayID) is not there; using \(display.displayID)") }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pointSize = CGSize(width: display.width, height: display.height)
        // Pixels per point: the mode says (a virtual display has none to ask), else the filter.
        var pixelWidth = Int((Float(display.width) * filter.pointPixelScale).rounded())
        var pixelHeight = Int((Float(display.height) * filter.pointPixelScale).rounded())
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
        }
        if let maxLongEdge, max(pixelWidth, pixelHeight) > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(max(pixelWidth, pixelHeight))
            pixelWidth = Int(Double(pixelWidth) * scale)
            pixelHeight = Int(Double(pixelHeight) * scale)
        }
        // H.264 wants even dimensions.
        pixelWidth &= ~1
        pixelHeight &= ~1

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = showsCursor
        config.queueDepth = 5
        config.capturesAudio = onAudio != nil
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.captureResolution = .best

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if config.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        startRefreshTimer()

        hostLog("[capture] display \(display.displayID) \(Int(pointSize.width))x\(Int(pointSize.height))pt -> \(pixelWidth)x\(pixelHeight)px")
        return Started(displayID: display.displayID,
                       pointSize: pointSize,
                       pixelSize: CGSize(width: pixelWidth, height: pixelHeight))
    }

    func stop() {
        refreshTimer?.cancel()
        refreshTimer = nil
        let stream = self.stream
        self.stream = nil
        outputQueue.async { self.lastBuffer = nil }
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid, let onAudio, let pcm = Self.interleavedInt16(sampleBuffer) { onAudio(pcm) }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        deliver(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        hostLog("[capture] stopped: \(error.localizedDescription)")
        onStop?(error)
    }

    // MARK: Private

    /// Float32 (planar or interleaved, mono or stereo) -> stereo Int16 interleaved.
    private static func interleavedInt16(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = Int(description.mChannelsPerFrame)
        let planar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        func sample(_ channel: Int, _ frame: Int) -> Float {
            let channel = min(channel, channels - 1)
            if planar {
                guard channel < buffers.count, let data = buffers[channel].mData else { return 0 }
                return data.assumingMemoryBound(to: Float.self)[frame]
            }
            guard let data = buffers[0].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * channels + channel]
        }

        var pcm = Data(count: frames * 4)
        var silent = true
        pcm.withUnsafeMutableBytes { bytes in
            let out = bytes.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let value = Int16(max(-1, min(1, sample(channel, frame))) * 32767)
                    if value != 0 { silent = false }
                    out[frame * 2 + channel] = value.littleEndian
                }
            }
        }
        // ScreenCaptureKit keeps delivering digital silence; skip it to save ~1.5 Mbps.
        return silent ? nil : pcm
    }

    /// Must run on `outputQueue`.
    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        lastBuffer = pixelBuffer
        lastDelivery = CACurrentMediaTime()
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer,
                                  rotation: ._0,
                                  timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
        sink.capturer(rtcCapturer, didCapture: frame)
        deliveredFrames += 1
        if deliveredFrames == 1 {
            hostLog("[capture] first frame \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
    }

    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now() + Self.idleRefreshInterval, repeating: Self.idleRefreshInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let last = self.lastBuffer else { return }
            if CACurrentMediaTime() - self.lastDelivery >= Self.idleRefreshInterval {
                self.deliver(last)
            }
        }
        timer.resume()
        refreshTimer = timer
    }
}

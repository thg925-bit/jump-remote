import WebRTC

/// Default WebRTC encoders plus hardware HEVC, and H.264 runs at level 5.2.
///
/// RTCVideoEncoderH264 caps its frame rate by the negotiated level's macroblock rate. On macOS
/// the default is level 3.1, which limits a Retina-size frame to a few fps. The level is only
/// a ceiling on what the decoder must handle; modern iPad/Android hardware decoders cope.
final class HighLevelH264EncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let fallback = RTCDefaultVideoEncoderFactory()

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        if info.name == HEVCEncoder.codecName { return HEVCEncoder() }
        guard info.name == kRTCVideoCodecH264Name else {
            return fallback.createEncoder(info)
        }
        var parameters = info.parameters
        let profile = RTCH264ProfileLevelId(hexString: parameters["profile-level-id"] ?? "")?.profile ?? .constrainedHigh
        let raised = RTCH264ProfileLevelId(profile: profile, level: RTCH264Level(rawValue: 52)!)
        parameters["profile-level-id"] = raised?.hexString ?? "640c34"
        return RTCVideoEncoderH264(codecInfo: RTCVideoCodecInfo(name: info.name, parameters: parameters))
    }

    /// HEVC (our VideoToolbox encoder) first; the default set after it.
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        [HEVCEncoder.codecInfo] + fallback.supportedCodecs()
    }
}

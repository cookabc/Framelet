import AVFoundation

/// Video compression passed to AVAssetWriter. H.264 favors playback compatibility; HEVC can
/// reduce file size, depending on content and the encoder available on the Mac.
public enum VideoCodec: String, CaseIterable, Codable {
    case h264
    case hevc

    public var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

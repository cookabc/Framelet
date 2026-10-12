import CoreGraphics

/// Give small screen recordings a bitrate floor so text does not inherit an undersized
/// encoder default. This remains lossy compression; bitrate targets are not file-size promises.
public enum ScreenVideoQuality {
    public static func averageBitRate(pixelSize: CGSize, fps: Int, codec: VideoCodec) -> Int {
        let pixels = pixelSize.width * pixelSize.height
        guard pixels.isFinite, pixels > 0 else { return 2_000_000 }
        let rate = Double(min(240, max(1, fps)))
        let bitsPerPixel = codec == .h264 ? 0.25 : 0.18
        let ceiling = codec == .h264 ? 80_000_000.0 : 60_000_000.0
        return Int(min(ceiling, max(2_000_000, Double(pixels) * rate * bitsPerPixel)))
    }
}

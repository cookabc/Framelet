import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: LocalizedError {
    case invalidRange, createFailed, finalizeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "That export range is not valid. Choose 0.1 to 60 seconds inside the video."
        case .createFailed:
            return "The animated image could not be created. Check the destination and the free space."
        case .finalizeFailed:
            return
                "The animated image could not be written. The original recording was kept, so you can export again."
        }
    }
}

public struct GIFSettings: Sendable {
    public let start: Double
    public let duration: Double
    public let fps: Int
    public let maxWidth: Int

    public init(start: Double, duration: Double, fps: Int = 15, maxWidth: Int = 960) {
        self.start = start
        self.duration = duration
        self.fps = fps
        self.maxWidth = maxWidth
    }
}

public enum GIFExporter {
    public static func export(
        video: URL, to output: URL, settings: GIFSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: video)
        let total = try await asset.load(.duration).seconds
        guard settings.start.isFinite, settings.duration.isFinite,
            settings.start >= 0, settings.duration >= 0.1, settings.duration <= 60,
            settings.start + settings.duration <= total + 0.05,
            (1...30).contains(settings.fps), (64...1920).contains(settings.maxWidth)
        else {
            throw ExportError.invalidRange
        }
        let staged = FileExport.stagingURL(for: output)
        defer { try? FileManager.default.removeItem(at: staged) }
        let count = max(1, Int(ceil(settings.duration * Double(settings.fps))))
        guard
            let destination = CGImageDestinationCreateWithURL(
                staged as CFURL, UTType.gif.identifier as CFString, count, nil)
        else {
            throw ExportError.createFailed
        }
        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: settings.maxWidth, height: settings.maxWidth)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let delay = settings.duration / Double(count)
        let properties =
            [
                kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: settings.start + Double(index) * delay, preferredTimescale: 60000)
            let (frame, _) = try await generator.image(at: time)
            autoreleasepool { CGImageDestinationAddImage(destination, frame, properties) }
            progress(Double(index + 1) / Double(count) * 0.97)
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw ExportError.finalizeFailed }
        try Task.checkCancellation()
        try FileExport.commit(staged, to: output)
        progress(1)
    }
}

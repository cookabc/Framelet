import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

public enum ExportError: LocalizedError {
    case invalidRange, invalidSettings, invalidDestination, createFailed, finalizeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "That export range is not valid. Choose 0.1 to 60 seconds inside the video."
        case .invalidSettings:
            return "Choose a frame rate from 1 to 30 and a long edge from 64 to 1920 pixels."
        case .invalidDestination:
            return "Choose a different destination. The original recording cannot be overwritten."
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
    /// Maximum long edge, preserving aspect ratio and track orientation.
    public let maxWidth: Int
    /// Diffuses quantization error for smoother gradients, at the cost of noise and file size.
    /// Disabling this keeps fills flat, but does not guarantee lossless source colors.
    public let dither: Bool

    public init(start: Double, duration: Double, fps: Int = 15, maxWidth: Int = 960, dither: Bool = false) {
        self.start = start
        self.duration = duration
        self.fps = fps
        self.maxWidth = maxWidth
        self.dither = dither
    }
}

public enum GIFExporter {
    public static func export(
        video: URL, to output: URL, settings: GIFSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !exportTargetsSource(video, output) else { throw ExportError.invalidDestination }
        let asset = AVURLAsset(url: video)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, settings.start.isFinite, settings.duration.isFinite,
            settings.start >= 0, settings.duration >= 0.1, settings.duration <= 60,
            settings.start + settings.duration <= total
        else { throw ExportError.invalidRange }
        guard (1...30).contains(settings.fps), (64...1920).contains(settings.maxWidth) else {
            throw ExportError.invalidSettings
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: settings.maxWidth, height: settings.maxWidth)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        try await withTaskCancellationHandler {
            try await encode(
                video: video, generator: generator, to: output, settings: settings, progress: progress)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    private static func encode(
        video: URL, generator: AVAssetImageGenerator, to output: URL, settings: GIFSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let staged = FileExport.stagingURL(for: output)
        defer { try? FileManager.default.removeItem(at: staged) }
        let count = max(1, Int(ceil(settings.duration * Double(settings.fps))))
        guard
            let destination = CGImageDestinationCreateWithURL(
                staged as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw ExportError.createFailed }
        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
        let delay = settings.duration / Double(count)
        progress(0)
        var histogram: GIFPalette.Histogram = [:]
        let samples = min(count, 12)
        for index in 0..<samples {
            try Task.checkCancellation()
            let time = CMTime(
                seconds: settings.start + Double(index) / Double(samples) * settings.duration,
                preferredTimescale: 60000)
            let frame = try await image(generator, at: time)
            try autoreleasepool { try accumulateHistogram(frame, into: &histogram) }
            progress(Double(index + 1) / Double(samples) * 0.1)
        }
        var palette = try GIFPalette.build(histogram: histogram)
        histogram.removeAll(keepingCapacity: false)
        progress(0.15)
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: settings.start + Double(index) * delay, preferredTimescale: 60000)
            let frame = try await image(generator, at: time)
            // GIF stores centiseconds. Round cumulative boundaries instead of rounding the
            // same fractional delay repeatedly, bounding total playback-time error to 5 ms.
            let ticks = max(
                1,
                Int((Double(index + 1) * delay * 100).rounded())
                    - Int((Double(index) * delay * 100).rounded()))
            let frameDelay = Double(ticks) / 100
            let properties =
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frameDelay,
                        kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                    ]
                ] as CFDictionary
            try autoreleasepool {
                let indexed = try quantize(frame, palette: &palette, dither: settings.dither)
                CGImageDestinationAddImage(destination, indexed, properties)
            }
            progress(0.15 + Double(index + 1) / Double(count) * 0.8)
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw ExportError.finalizeFailed }
        try Task.checkCancellation()
        guard !exportTargetsSource(video, output) else { throw ExportError.invalidDestination }
        try FileExport.commit(staged, to: output)
        progress(1)
    }

    private static func image(_ generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        do {
            let (frame, _) = try await generator.image(at: time)
            try Task.checkCancellation()
            return frame
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func rgbContext(_ frame: CGImage) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8,
                bytesPerRow: frame.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ExportError.createFailed }
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        return context
    }

    private static func accumulateHistogram(_ frame: CGImage, into histogram: inout GIFPalette.Histogram)
        throws
    {
        let context = try rgbContext(frame)
        guard let data = context.data else { throw ExportError.createFailed }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<frame.height {
            try Task.checkCancellation()
            for x in stride(from: 0, to: frame.width, by: 2) {
                let at = (y * frame.width + x) * 4
                GIFPalette.accumulate(
                    red: pixels[at], green: pixels[at + 1], blue: pixels[at + 2], into: &histogram)
            }
        }
    }

    private static func quantize(_ frame: CGImage, palette: inout GIFPalette, dither: Bool) throws -> CGImage
    {
        let width = frame.width
        let height = frame.height
        let context = try rgbContext(frame)
        guard let sourceData = context.data else { throw ExportError.createFailed }
        let pixels = sourceData.assumingMemoryBound(to: UInt8.self)
        var indices = [UInt8](repeating: 0, count: width * height)
        // Only the current and next row carry error. Padding removes edge-index hazards.
        var current = [Float](repeating: 0, count: dither ? (width + 2) * 3 : 0)
        var next = current
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let at = (y * width + x) * 4
                if !dither {
                    indices[y * width + x] = palette.index(
                        for: pixels[at], green: pixels[at + 1], blue: pixels[at + 2])
                    continue
                }
                let base = (x + 1) * 3
                let r = min(255, max(0, Float(pixels[at]) + current[base]))
                let g = min(255, max(0, Float(pixels[at + 1]) + current[base + 1]))
                let b = min(255, max(0, Float(pixels[at + 2]) + current[base + 2]))
                let entry = palette.index(for: UInt8(r), green: UInt8(g), blue: UInt8(b))
                indices[y * width + x] = entry
                let color = palette.color(at: entry)
                let errors = (r - Float(color.red), g - Float(color.green), b - Float(color.blue))
                for channel in 0..<3 {
                    let error = channel == 0 ? errors.0 : channel == 1 ? errors.1 : errors.2
                    current[base + 3 + channel] += error * (7.0 / 16)
                    next[base - 3 + channel] += error * (3.0 / 16)
                    next[base + channel] += error * (5.0 / 16)
                    next[base + 3 + channel] += error * (1.0 / 16)
                }
            }
            if dither {
                swap(&current, &next)
                for index in next.indices { next[index] = 0 }
            }
        }
        let table = palette.colorTable
        guard let baseSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let indexedSpace = CGColorSpace(
                indexedBaseSpace: baseSpace, last: table.count / 3 - 1, colorTable: table),
            let provider = CGDataProvider(data: Data(indices) as CFData),
            let indexed = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: indexedSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ExportError.createFailed }
        return indexed
    }
}

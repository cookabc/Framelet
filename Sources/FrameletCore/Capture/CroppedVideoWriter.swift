import AVFoundation
import CoreImage
import os

/// Crops composed display frames before encoding. Pixels outside the selection are never written to disk.
public final class CroppedVideoWriter: @unchecked Sendable {
    private static let log = Logger(subsystem: "studio.framelet", category: "crop-writer")
    private let queue = DispatchQueue(label: "studio.framelet.crop-writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let source: CGRect
    private let displaySize: CGSize
    private let outputSize: CGSize
    private let frameInterval: CMTime
    private let url: URL
    private let onStarted: () -> Void
    private let onFailure: (Error) -> Void
    // Accessed only on queue.
    private var lastTime: CMTime?
    private var lastAppendUptime = 0.0
    private var ending = false
    private var failure: Error?

    public init(
        url: URL, source: CGRect, displaySize: CGSize, outputSize: CGSize, fps: Int,
        onStarted: @escaping () -> Void = {}, onFailure: @escaping (Error) -> Void = { _ in }
    ) throws {
        guard
            [
                source.minX, source.minY, source.width, source.height,
                displaySize.width, displaySize.height,
            ].allSatisfy({ $0.isFinite }),
            source.width > 0, source.height > 0, source.minX >= 0, source.minY >= 0,
            displaySize.width > 0, displaySize.height > 0,
            CGRect(origin: .zero, size: displaySize).contains(source)
        else { throw Self.error("The recording area is outside the display.") }
        guard
            [outputSize.width, outputSize.height].allSatisfy({ $0.isFinite }),
            outputSize.width >= 2, outputSize.height >= 2,
            outputSize.width <= 8192, outputSize.height <= 8192,
            outputSize.width.truncatingRemainder(dividingBy: 2) == 0,
            outputSize.height.truncatingRemainder(dividingBy: 2) == 0, (1...240).contains(fps)
        else { throw Self.error("The recording settings are outside the supported range.", code: 2) }
        self.url = url
        self.source = source
        self.displaySize = displaySize
        self.outputSize = outputSize
        self.frameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        self.onStarted = onStarted
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width), AVVideoHeightKey: Int(outputSize.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        guard writer.canAdd(input) else { throw Self.error("The video encoder could not be configured.") }
        writer.add(input)
    }

    /// Called on the stream's serial sample queue. The bounded encoder queue supplies backpressure
    /// instead of retaining an unbounded queue of full-display pixel buffers.
    public func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        queue.sync {
            guard !ending, failure == nil, time.isNumeric,
                lastTime.map({ time > $0 }) ?? true
            else { return }
            do {
                if writer.status == .unknown {
                    guard writer.startWriting() else {
                        throw writer.error ?? Self.error("The video encoder could not start.")
                    }
                    writer.startSession(atSourceTime: time)
                }
                guard writer.status == .writing else {
                    throw writer.error ?? Self.error("The video encoder stopped unexpectedly.")
                }
                guard input.isReadyForMoreMediaData else {
                    // Backpressure drops frames rather than queueing whole display buffers; the
                    // timeline stays correct because every appended frame keeps its own timestamp.
                    Self.log.debug("The encoder is behind; dropped a video frame.")
                    return
                }
                guard let pool = adaptor.pixelBufferPool else {
                    throw Self.error("The video encoder did not allocate its frame pool.")
                }
                var destination: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                    let destination
                else { throw Self.error("There was not enough memory for a video frame.") }
                let sx = CGFloat(CVPixelBufferGetWidth(buffer)) / displaySize.width
                let sy = CGFloat(CVPixelBufferGetHeight(buffer)) / displaySize.height
                // Screen coordinates count down from the top; Core Image counts up from the bottom.
                let crop = CGRect(
                    x: source.minX * sx, y: (displaySize.height - source.maxY) * sy,
                    width: source.width * sx, height: source.height * sy)
                let image = CIImage(cvPixelBuffer: buffer).cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .transformed(
                        by: CGAffineTransform(
                            scaleX: outputSize.width / crop.width, y: outputSize.height / crop.height))
                context.render(
                    image, to: destination, bounds: CGRect(origin: .zero, size: outputSize),
                    colorSpace: colorSpace)
                guard adaptor.append(destination, withPresentationTime: time) else {
                    throw writer.error ?? Self.error("A video frame could not be saved.")
                }
                let first = lastTime == nil
                lastTime = time
                lastAppendUptime = ProcessInfo.processInfo.systemUptime
                if first { onStarted() }
            } catch {
                failure = error
                writer.cancelWriting()
                onFailure(error)
            }
        }
    }

    public func finish() async throws -> URL {
        let stopUptime = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !ending else {
                    continuation.resume(throwing: Self.error("This video segment has already ended."))
                    return
                }
                ending = true
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                guard let lastTime else {
                    writer.cancelWriting()
                    continuation.resume(throwing: Self.error("The display did not produce a video frame."))
                    return
                }
                // Static displays may stop sending new frames. Hold the last frame until Stop.
                let tail = max(frameInterval.seconds, stopUptime - lastAppendUptime)
                writer.endSession(atSourceTime: lastTime + CMTime(seconds: tail, preferredTimescale: 60000))
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(
                            throwing: writer.error ?? Self.error("The video could not be finished."))
                    }
                }
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            guard !ending else { return }
            ending = true
            writer.cancelWriting()
        }
    }

    private static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(
            domain: "Framelet.CroppedVideoWriter", code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import AVFoundation
import CoreImage
import os

/// Crops before encoding. Only selected pixels reach disk. All timeline and encoder mutations
/// are serialized; pauses remove their actual host-clock span, not gaps between static frames.
public final class CroppedVideoWriter: @unchecked Sendable {
    private static let log = Logger(subsystem: "studio.framelet", category: "crop-writer")
    private let queue = DispatchQueue(label: "studio.framelet.crop-writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let displaySize: CGSize
    private let outputSize: CGSize
    private let frameInterval: CMTime
    private let url: URL
    private let onStarted: () -> Void
    private let onFailure: (Error) -> Void
    private let uptime: () -> Double
    private var source: CGRect
    // Accessed only on queue.
    private var lastTime: CMTime?
    private var lastMediaTime: CMTime?
    private var lastAppendUptime = 0.0
    private var pauseOffsetAtAppend = 0.0
    private var pauseStarted: Double?
    private var accumulatedPause = 0.0
    private var ending = false
    private var failure: Error?
    private var finishResult: Result<URL, Error>?
    private var finishWaiters: [CheckedContinuation<URL, Error>] = []
    private var needsRefresh = false

    public init(
        url: URL, source: CGRect, displaySize: CGSize, outputSize: CGSize, fps: Int,
        codec: VideoCodec = .h264,
        onStarted: @escaping () -> Void = {}, onFailure: @escaping (Error) -> Void = { _ in },
        uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        guard
            [source.minX, source.minY, source.width, source.height, displaySize.width, displaySize.height]
                .allSatisfy({ $0.isFinite }),
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
        self.uptime = uptime
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec.avCodecType,
                AVVideoWidthKey: Int(outputSize.width), AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoAllowFrameReorderingKey: false,
                ],
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

    /// The stream queue blocks instead of retaining an unbounded queue of full-display buffers.
    @discardableResult
    public func append(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        queue.sync {
            let appended = appendOnQueue(buffer, at: time)
            // A synthetic annotation frame can overtake a delayed stream sample. Retry the
            // latest complete surface at host time, so its final content change is not lost.
            if !appended, !ending, failure == nil, pauseStarted == nil { needsRefresh = true }
            return appended
        }
    }

    /// Reuses one retained complete buffer on a static screen. No pixel copy is made. Plain
    /// recordings skip encoding; marks, clears, crop moves and resume request a fresh picture.
    public func refresh(_ buffer: CVPixelBuffer, at time: CMTime) {
        queue.sync {
            guard !ending, failure == nil, pauseStarted == nil, let lastTime,
                time.isNumeric, time > lastTime,
                (time - lastTime).seconds >= frameInterval.seconds * 0.95
            else { return }
            guard needsRefresh
            else { return }
            _ = appendOnQueue(buffer, at: time)
        }
    }

    private func appendOnQueue(_ buffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard !ending, failure == nil, pauseStarted == nil, time.isNumeric,
            lastTime.map({ time > $0 }) ?? true
        else { return false }
        let mediaTime = time - CMTime(seconds: accumulatedPause, preferredTimescale: 1_000_000_000)
        // A delayed stream sample arriving after resume must not regress the encoded timeline.
        guard lastMediaTime.map({ mediaTime > $0 }) ?? true else { return false }
        do {
            if writer.status == .unknown {
                guard writer.startWriting() else {
                    throw writer.error ?? Self.error("The video encoder could not start.")
                }
                writer.startSession(atSourceTime: mediaTime)
            }
            guard writer.status == .writing else {
                throw writer.error ?? Self.error("The video encoder stopped unexpectedly.")
            }
            guard input.isReadyForMoreMediaData else {
                Self.log.debug("The encoder is behind; dropped a video frame.")
                return false
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
            guard adaptor.append(destination, withPresentationTime: mediaTime) else {
                throw writer.error ?? Self.error("A video frame could not be saved.")
            }
            let first = lastTime == nil
            lastTime = time
            lastMediaTime = mediaTime
            lastAppendUptime = uptime()
            pauseOffsetAtAppend = accumulatedPause
            needsRefresh = false
            if first { onStarted() }
            return true
        } catch {
            failure = error
            // Do not delete/cancel partial output or promise that a failed encoder is salvageable.
            // The model retains nonempty files for explicit recovery handling.
            onFailure(error)
            return false
        }
    }

    /// Returns only once the writer queue has gated appending and recorded the pause boundary.
    public func pause() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !ending, failure == nil, pauseStarted == nil { pauseStarted = uptime() }
                continuation.resume()
            }
        }
    }

    public func resume() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !ending, let started = pauseStarted {
                    accumulatedPause += max(0, uptime() - started)
                    pauseStarted = nil
                    needsRefresh = true
                }
                continuation.resume()
            }
        }
    }

    /// All callers share the same finalization result, including stop/error races.
    public func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let finishResult {
                    continuation.resume(with: finishResult)
                    return
                }
                finishWaiters.append(continuation)
                guard !ending else { return }
                ending = true
                if let failure {
                    completeFinish(.failure(failure))
                    return
                }
                guard let lastMediaTime else {
                    writer.cancelWriting()
                    completeFinish(.failure(Self.error("The display did not produce a video frame.")))
                    return
                }
                let stop = uptime()
                let totalPause = accumulatedPause + (pauseStarted.map { max(0, stop - $0) } ?? 0)
                // Hold static content through active time on either side of a pause, even if no
                // new stream frame arrived after resume. Never extend through the paused span.
                let activeTail = max(0, stop - lastAppendUptime - (totalPause - pauseOffsetAtAppend))
                writer.endSession(
                    atSourceTime: lastMediaTime
                        + CMTime(
                            seconds: max(frameInterval.seconds, activeTail), preferredTimescale: 1_000_000_000
                        ))
                input.markAsFinished()
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        if writer.status == .completed {
                            completeFinish(.success(url))
                        } else {
                            completeFinish(
                                .failure(writer.error ?? Self.error("The video could not be finished.")))
                        }
                    }
                }
            }
        }
    }

    private func completeFinish(_ result: Result<URL, Error>) {
        finishResult = result
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for continuation in waiters { continuation.resume(with: result) }
    }

    public func cancel() {
        queue.async { [self] in
            guard !ending else { return }
            ending = true
            writer.cancelWriting()
            completeFinish(.failure(Self.error("The recording was cancelled.")))
        }
    }

    private static func error(_ message: String, code: Int = 1) -> NSError {
        NSError(
            domain: "Framelet.CroppedVideoWriter", code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

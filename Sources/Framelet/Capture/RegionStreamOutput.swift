import AVFoundation
import FrameletCore
import ScreenCaptureKit

/// Keeps just one complete surface buffer for bounded static-screen annotation refreshes.
final class RegionStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: CroppedVideoWriter
    let region: CaptureRegion?
    let queue = DispatchQueue(label: "studio.framelet.region-frames")
    // Accessed only on queue. Retain the surface; never copy its pixels or queue refresh tasks.
    private var latest: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var ending = false

    init(writer: CroppedVideoWriter, region: CaptureRegion?, fps: Int) {
        self.writer = writer
        self.region = region
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0 / Double(fps), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in
            guard let self, !self.ending, let latest = self.latest else { return }
            self.writer.refresh(latest, at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        self.timer = timer
        timer.resume()
    }

    /// The engine owns stream shutdown. Freeze refreshes and drain sample work before ending
    /// the writer; its finish result is shared by concurrent callers.
    func finish() async throws -> URL {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                ending = true
                timer?.cancel()
                timer = nil
                latest = nil
                continuation.resume()
            }
        }
        return try await writer.finish()
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard !ending, type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status == SCFrameStatus.complete.rawValue,
            let image = sampleBuffer.imageBuffer
        else { return }
        latest = image
        writer.append(image, at: sampleBuffer.presentationTimeStamp)
    }

    deinit { timer?.cancel() }
}

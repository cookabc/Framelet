import FrameletCore
import ScreenCaptureKit

/// ScreenCaptureKit supplies the whole display; the writer persists only the chosen rectangle.
final class RegionStreamOutput: NSObject, SCStreamOutput {
    let writer: CroppedVideoWriter
    let queue = DispatchQueue(label: "studio.framelet.region-frames")

    init(writer: CroppedVideoWriter) { self.writer = writer }

    func finish() async throws -> URL {
        // stopCapture has completed; drain any samples already enqueued before finishing the file.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        return try await writer.finish()
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status == SCFrameStatus.complete.rawValue,
            let image = sampleBuffer.imageBuffer
        else { return }
        writer.append(image, at: sampleBuffer.presentationTimeStamp)
    }
}

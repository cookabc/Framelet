import AppKit
import FrameletCore

@MainActor
protocol RecordingCapturing: AnyObject {
    var onStarted: (() -> Void)? { get set }
    var onFinished: ((Result<URL, Error>) -> Void)? { get set }
    func start(
        region: CaptureRegion, url: URL, fps: Int, cursor: Bool, codec: VideoCodec
    ) async throws
    func pause() async
    func resume() async
    func stop() async
}

extension CaptureEngine: RecordingCapturing {}

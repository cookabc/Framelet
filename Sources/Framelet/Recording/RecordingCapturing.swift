import AppKit
import FrameletCore

@MainActor
protocol RecordingCapturing: AnyObject {
    var onStarted: (() -> Void)? { get set }
    var onFinished: ((Result<URL, Error>) -> Void)? { get set }
    func start(
        region: CaptureRegion, url: URL, fps: Int, cursor: Bool, codec: VideoCodec,
        effects: RecordingEffects?, clicks: Bool
    ) async throws
    func pause() async
    func resume() async
    func stop() async
    func moveRegion(to rect: CGRect) -> Bool
}

extension CaptureEngine: RecordingCapturing {}

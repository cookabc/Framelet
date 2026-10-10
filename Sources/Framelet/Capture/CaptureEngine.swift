import AVFoundation
import AppKit
import FrameletCore
import ScreenCaptureKit

struct CaptureRegion {
    let screen: NSScreen
    let rect: CGRect
    var windowID: CGWindowID? = nil
    var ownerPID: pid_t? = nil
    var title: String = "Region"
    var displayID: CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
final class CaptureEngine: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var completed = false
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?

    func start(region: CaptureRegion, url: URL, fps: Int, cursor: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        if let windowID = region.windowID {
            guard
                let window = content.windows.first(where: {
                    $0.windowID == windowID && $0.owningApplication?.processID == region.ownerPID
                })
            else {
                throw NSError(
                    domain: "Framelet", code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected window closed. Stop to save what was recorded, or choose another window."
                    ])
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.ignoreShadowsSingleWindow = true
            config.scalesToFit = true
            config.preservesAspectRatio = true
        } else {
            guard
                let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                        == region.displayID
                }), screen.frame == region.screen.frame,
                let display = content.displays.first(where: { $0.displayID == region.displayID }),
                let source = CaptureGeometry.sourceRect(selection: region.rect, screen: screen.frame)
            else {
                throw NSError(
                    domain: "Framelet", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "That display is gone or its layout changed. Select the area again."
                    ])
            }
            let ownApps = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config.sourceRect = source
        }
        let size = CaptureGeometry.pixelSize(
            points: region.rect.size, scale: region.screen.backingScaleFactor)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.showsCursor = cursor
        config.capturesAudio = false
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.videoCodecType = .h264
        recordingConfig.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        self.output = output
        self.url = url
        try stream.addRecordingOutput(output)
        do { try await stream.startCapture() } catch {
            completed = true
            self.stream = nil
            self.output = nil
            throw error
        }
    }

    func stop() async {
        do { try await stream?.stopCapture() } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        stream = nil
        output = nil
        onFinished?(result)
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard !self.completed else { return }
            self.onStarted?()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let url = self.url else { return }
            self.finish(.success(url))
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            let activeStream = self.stream
            self.finish(.failure(error))
            try? await activeStream?.stopCapture()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}

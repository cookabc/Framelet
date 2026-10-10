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
    private var regionOutput: RegionStreamOutput?
    private var url: URL?
    private var completed = false
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?

    func start(region: CaptureRegion, url: URL, fps: Int, cursor: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        let size = CaptureGeometry.pixelSize(
            points: region.rect.size, scale: region.screen.backingScaleFactor)
        config.width = Int(size.width)
        config.height = Int(size.height)
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
            // Keep popup composition independent of the selection bounds: crop composed frames
            // ourselves instead of asking WindowServer to render a partial display sourceRect.
            // Only cropped buffers reach the encoder; full-display frames remain in memory.
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            let writer = try CroppedVideoWriter(
                url: url, source: source, displaySize: screen.frame.size, outputSize: size, fps: fps,
                onStarted: { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.completed else { return }
                        self.onStarted?()
                    }
                },
                onFailure: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        let stream = self.stream
                        self.finish(.failure(error))
                        try? await stream?.stopCapture()
                    }
                })
            regionOutput = RegionStreamOutput(writer: writer)
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = region.windowID == nil ? 3 : 5
        config.showsCursor = cursor
        config.capturesAudio = false
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        self.url = url
        do {
            if let regionOutput {
                try stream.addStreamOutput(
                    regionOutput, type: .screen, sampleHandlerQueue: regionOutput.queue)
            } else {
                let recordingConfig = SCRecordingOutputConfiguration()
                recordingConfig.outputURL = url
                recordingConfig.videoCodecType = .h264
                recordingConfig.outputFileType = .mp4
                let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
                self.output = output
                try stream.addRecordingOutput(output)
            }
            try await stream.startCapture()
        } catch {
            completed = true
            regionOutput?.writer.cancel()
            regionOutput = nil
            self.stream = nil
            self.output = nil
            throw error
        }
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
            if let regionOutput { finish(.success(try await regionOutput.finish())) }
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        if case .failure = result { regionOutput?.writer.cancel() }
        regionOutput = nil
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

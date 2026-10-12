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

struct CaptureInterruptionError: LocalizedError {
    let recoveredURL: URL?
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

@MainActor
final class CaptureEngine: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var output: RegionStreamOutput?
    private var completed = false
    private var requestedStart = false
    private var finalization: Task<Void, Never>?
    private var interruption: Error?
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?

    func start(
        region: CaptureRegion, url: URL, fps: Int, cursor: Bool
    ) async throws {
        guard !requestedStart else { throw Self.error("This capture has already been started.") }
        requestedStart = true
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        let source: CGRect
        let surfaceSize: CGSize
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
                throw Self.error("The selected window closed. Choose another window.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.ignoreShadowsSingleWindow = true
            config.scalesToFit = true
            config.preservesAspectRatio = true
            source = CGRect(origin: .zero, size: region.rect.size)
            surfaceSize = region.rect.size
        } else {
            guard
                let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                        == region.displayID
                }), screen.frame == region.screen.frame,
                let display = content.displays.first(where: { $0.displayID == region.displayID }),
                let crop = CaptureGeometry.sourceRect(selection: region.rect, screen: screen.frame),
                crop.size == region.rect.size
            else { throw Self.error("That display is gone or its layout changed. Select the area again.") }
            let ownApps = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            // Cropping after display composition keeps transient popup content independent of
            // the selection edges. Only cropped buffers reach the encoder.
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            source = crop
            surfaceSize = screen.frame.size
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = cursor
        config.capturesAudio = false
        let writer = try CroppedVideoWriter(
            url: url, source: source, displaySize: surfaceSize, outputSize: size, fps: fps,
            onStarted: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.completed, self.finalization == nil else { return }
                    self.onStarted?()
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in await self?.finalize(interruptedBy: error) }
            })
        let output = RegionStreamOutput(
            writer: writer, region: region.windowID == nil ? region : nil, fps: fps)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.output = output
        self.stream = stream
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
        } catch {
            // Once a writer exists, finalization is reported through onFinished so a partial,
            // completed file and its original failure travel together to the library.
            await finalize(interruptedBy: error)
        }
    }

    func pause() async { await output?.writer.pause() }
    func resume() async { await output?.writer.resume() }

    func stop() async { await finalize() }

    private func finalize(interruptedBy error: Error? = nil, alreadyStopped: Bool = false) async {
        guard !completed else { return }
        if let error, interruption == nil { interruption = error }
        if let finalization {
            await finalization.value
            return
        }
        let activeStream = stream
        let activeOutput = output
        let task = Task { @MainActor [self] in
            if !alreadyStopped {
                do { try await activeStream?.stopCapture() } catch {
                    if interruption == nil { interruption = error }
                }
            }
            let result: Result<URL, Error>
            do {
                guard let activeOutput else { throw Self.error("The capture did not produce a recording.") }
                let url = try await activeOutput.finish()
                if let interruption {
                    result = .failure(CaptureInterruptionError(recoveredURL: url, underlying: interruption))
                } else {
                    result = .success(url)
                }
            } catch {
                result = .failure(
                    CaptureInterruptionError(recoveredURL: nil, underlying: interruption ?? error))
            }
            completed = true
            stream = nil
            output = nil
            onFinished?(result)
        }
        finalization = task
        await task.value
        finalization = nil
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in await self.finalize(interruptedBy: error, alreadyStopped: true) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Framelet.Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

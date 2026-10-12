import AVFoundation
import AppKit
import FrameletCore
import Vision
import XCTest

@testable import Framelet

@MainActor
private final class TestCapture: RecordingCapturing {
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?
    var effects: RecordingEffects?
    var region: CaptureRegion?
    var url: URL?
    var clicks = false
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var pauseDelay: CheckedContinuation<Void, Never>?
    var delaysPause = false

    func start(
        region: CaptureRegion, url: URL, fps: Int, cursor: Bool, codec: VideoCodec,
        effects: RecordingEffects?, clicks: Bool
    ) async throws {
        self.region = region
        self.url = url
        self.effects = effects
        self.clicks = clicks
        onStarted?()
    }
    func pause() async {
        pauseCalls += 1
        if delaysPause { await withCheckedContinuation { pauseDelay = $0 } }
    }
    func resume() async { resumeCalls += 1 }
    func stop() async { stopCalls += 1 }
}

@MainActor
final class RecorderLifecycleTests: XCTestCase {
    private func fixture() throws -> (RecorderModel, TestCapture, CaptureRegion, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lifecycle-\(UUID().uuidString)")
        let suite = "FrameletLifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let capture = TestCapture()
        let model = RecorderModel(libraryURL: root, defaults: defaults, engineFactory: { capture })
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let region = CaptureRegion(
            screen: screen,
            rect: CGRect(
                x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 200, height: 120))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (model, capture, region, root)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The recording transition did not complete")
    }

    private func finish(_ capture: TestCapture, model: RecorderModel, result: Result<URL, Error>) async throws
    {
        capture.onFinished?(result)
        try await settle { model.phase == .idle }
    }

    func testFirstTakeGetsItsOwnAnnotationStoreBeforeCaptureStarts() async throws {
        let (model, capture, region, root) = try fixture()
        model.showsClicks = true
        await model.beginRecording(region: region)
        XCTAssertEqual(model.phase, .recording)
        XCTAssertTrue(model.canAnnotate)
        XCTAssertTrue(capture.clicks)
        let first = try XCTUnwrap(capture.effects)
        XCTAssertTrue(first.snapshot(at: 0).marks.isEmpty)
        model.toggleAnnotating()
        XCTAssertTrue(model.isAnnotating)
        model.setAnnotating(false)
        await model.beginRecording(region: region)
        XCTAssertTrue(capture.effects === first, "An active take cannot be replaced by a second start")
        try await finish(capture, model: model, result: .failure(CocoaError(.fileWriteUnknown)))
        XCTAssertFalse(model.canAnnotate)
        XCTAssertFalse(model.isAnnotating)
        XCTAssertTrue(RecordingLibrary.unfinishedSessions(in: root).isEmpty)
        await model.beginRecording(region: region)
        let second = try XCTUnwrap(capture.effects)
        XCTAssertFalse(first === second)
        try await finish(capture, model: model, result: .failure(CocoaError(.fileWriteUnknown)))
    }

    func testPauseAndResumeConfirmWithoutRecreatingTheCapture() async throws {
        let (model, capture, region, _) = try fixture()
        await model.beginRecording(region: region)
        let store = try XCTUnwrap(capture.effects)
        model.toggleAnnotating()
        model.togglePause()
        XCTAssertFalse(model.annotating)
        XCTAssertEqual(model.phase, .recording)
        XCTAssertTrue(model.pauseIsChanging)
        XCTAssertTrue(model.canControlRecording)
        try await settle { model.phase == .paused }
        XCTAssertFalse(model.pauseIsChanging)
        XCTAssertEqual(capture.pauseCalls, 1)
        XCTAssertTrue(capture.effects === store)
        XCTAssertTrue(model.canAnnotate)
        model.togglePause()
        try await settle { model.phase == .recording }
        XCTAssertEqual(capture.resumeCalls, 1)
        XCTAssertTrue(capture.effects === store)
        try await finish(capture, model: model, result: .failure(CocoaError(.fileWriteUnknown)))
    }

    func testRenderedPausedControlsUpdateWithoutReplacingTheirHostingView() async throws {
        let (model, capture, area, _) = try fixture()
        let region = CaptureRegion(
            screen: area.screen, rect: area.rect, windowID: 42,
            ownerPID: 123, title: "Probe window")
        await model.beginRecording(region: region)
        let controls = RecordingPanel(model: model)
        controls.show(near: region)
        defer { controls.close() }
        let initialView = try XCTUnwrap(controls.window.contentView)
        model.togglePause()
        try await settle { model.phase == .paused }
        try await Task.sleep(for: .milliseconds(150))
        let pausedView = try XCTUnwrap(controls.window.contentView)
        XCTAssertTrue(pausedView === initialView)
        pausedView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(pausedView.bitmapImageRepForCachingDisplay(in: pausedView.bounds))
        pausedView.cacheDisplay(in: pausedView.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let labels =
            request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        XCTAssertTrue(
            labels.contains("Paused"), "The actual controls must show Paused, not Starting: \(labels)")
        XCTAssertFalse(labels.contains("Starting"))
        if let folder = ProcessInfo.processInfo.environment["FRAMELET_UI_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("paused-controls.png"))
        }
        model.togglePause()
        try await settle { model.phase == .recording }
        XCTAssertTrue(controls.window.contentView === initialView)
        try await finish(capture, model: model, result: .failure(CocoaError(.fileWriteUnknown)))
    }

    func testStopRemainsAvailableDuringAnUnfinishedPauseAcknowledgement() async throws {
        let (model, capture, region, _) = try fixture()
        capture.delaysPause = true
        await model.beginRecording(region: region)
        model.togglePause()
        try await settle { capture.pauseDelay != nil }
        model.togglePause()
        XCTAssertEqual(capture.pauseCalls, 1, "A second click must not queue another pause")
        XCTAssertTrue(model.canControlRecording)
        model.stopRecording()
        try await settle { capture.stopCalls == 1 }
        XCTAssertEqual(model.phase, .stopping)
        capture.pauseDelay?.resume()
        capture.pauseDelay = nil
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.phase, .stopping, "Late pause completion must not reopen a stopping take")
        try await finish(capture, model: model, result: .failure(CocoaError(.fileWriteUnknown)))
        XCTAssertFalse(model.pauseIsChanging)
    }

    func testWindowTakeDoesNotOfferFixedAreaAnnotationOrMove() async throws {
        let (model, capture, area, _) = try fixture()
        let window = CaptureRegion(
            screen: area.screen, rect: area.rect, windowID: 42, ownerPID: 123, title: "Test")
        await model.beginRecording(region: window)
        XCTAssertNil(capture.effects)
        XCTAssertFalse(model.canAnnotate)
        model.toggleAnnotating()
        XCTAssertFalse(model.isAnnotating)
        let controls = RecordingPanel(model: model)
        controls.show(near: window)
        XCTAssertNil(controls.border)
        controls.close()
        try await finish(capture, model: model, result: .failure(CocoaError(.fileWriteUnknown)))
    }

    func testSuccessfulCaptureIsValidatedBeforeEnteringTheLibrary() async throws {
        let (model, capture, region, root) = try fixture()
        let scratch = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let sample = try await makeRecoverySegment(in: scratch)
        await model.beginRecording(region: region)
        let staged = try XCTUnwrap(capture.url)
        XCTAssertEqual(
            staged.deletingLastPathComponent().deletingLastPathComponent(),
            RecordingLibrary.sessionContainer(in: root))
        XCTAssertTrue(model.clips.isEmpty)
        try FileManager.default.copyItem(at: sample, to: staged)
        try await finish(capture, model: model, result: .success(staged))
        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(model.notice, "Recording saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(RecordingLibrary.unfinishedSessions(in: root).isEmpty)
    }

    func testNonemptyUndecodableTakeIsNotDeletedOrReportedAsSuccess() async throws {
        let (model, capture, region, root) = try fixture()
        await model.beginRecording(region: region)
        let staged = try XCTUnwrap(capture.url)
        let partial = Data("Incomplete video".utf8)
        try partial.write(to: staged)
        try await finish(
            capture, model: model,
            result: .failure(
                CaptureInterruptionError(
                    recoveredURL: nil, underlying: CocoaError(.fileWriteUnknown))))
        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNotEqual(model.notice, "Recording saved")
        XCTAssertEqual(try Data(contentsOf: staged), partial)
        XCTAssertEqual(RecordingLibrary.unfinishedSessions(in: root).count, 1)
        await model.recoverUnfinishedSessions()
        XCTAssertEqual(try Data(contentsOf: staged), partial)
        XCTAssertFalse(model.recovering)
    }

    func testRecoveredInterruptionSavesPlayableVideoButRetainsTheError() async throws {
        let (model, capture, region, root) = try fixture()
        let scratch = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let sample = try await makeRecoverySegment(in: scratch)
        await model.beginRecording(region: region)
        let staged = try XCTUnwrap(capture.url)
        try FileManager.default.copyItem(at: sample, to: staged)
        try await finish(
            capture, model: model,
            result: .failure(
                CaptureInterruptionError(
                    recoveredURL: staged, underlying: CocoaError(.fileReadUnknown))))
        XCTAssertEqual(model.clips.count, 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.notice, "Recording interrupted; captured video saved")
        XCTAssertTrue(RecordingLibrary.unfinishedSessions(in: root).isEmpty)
    }

    func testExportRangeDefaultsAndBoundsArePerClipAndFormat() async throws {
        let (model, _, _, _) = try fixture()
        model.duration = 120
        model.resetExportRange()
        XCTAssertEqual(model.exportStart, 0)
        XCTAssertEqual(model.exportDuration, 120)
        model.setExportStart(30)
        XCTAssertEqual(model.exportDuration, 90)
        model.setExportDuration(5)
        XCTAssertEqual(model.exportDuration, 5)
        model.setExportFormat(.gif)
        XCTAssertEqual(model.exportDuration, 10)
        XCTAssertEqual(model.maxExportDuration, 60)
        model.setExportDuration(100)
        XCTAssertEqual(model.exportDuration, 60)
        model.setExportStart(119)
        XCTAssertEqual(model.exportDuration, 1)
        model.setExportStart(.nan)
        XCTAssertEqual(model.exportStart, 0)
        model.setExportFormat(.video)
        XCTAssertEqual(model.exportDuration, 120)
    }

    func testSuccessfulRecoveryPreservesUnrelatedSessionFiles() async throws {
        let (model, _, _, root) = try fixture()
        let session = RecordingLibrary.newSessionURL(in: root)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try await makeRecoverySegment(in: session)
        let notes = session.appendingPathComponent("notes.txt")
        let data = Data("Preserve even after successful recovery".utf8)
        try data.write(to: notes)
        await model.recoverUnfinishedSessions()
        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(try Data(contentsOf: notes), data)
        XCTAssertTrue(RecordingLibrary.usableSegments(in: session).isEmpty)
        XCTAssertNotNil(model.selected)
    }

    func testUnknownNonVideoRecoveryFilesArePreserved() async throws {
        let (model, _, _, root) = try fixture()
        let session = RecordingLibrary.newSessionURL(in: root)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let notes = session.appendingPathComponent("notes.txt")
        try Data("Do not discard".utf8).write(to: notes)
        XCTAssertFalse(RecordingLibrary.isEmptySession(session))
        await model.recoverUnfinishedSessions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertTrue(model.notice?.contains("could not be joined") == true)
    }
}

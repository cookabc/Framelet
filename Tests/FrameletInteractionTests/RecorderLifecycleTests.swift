import AVFoundation
import AppKit
import FrameletCore
import XCTest

@testable import Framelet

@MainActor
private final class TestCapture: RecordingCapturing {
    var onStarted: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?
    var region: CaptureRegion?
    var url: URL?
    var pauseCalls = 0
    var resumeCalls = 0
    var stopCalls = 0
    var pauseDelay: CheckedContinuation<Void, Never>?
    var delaysPause = false

    func start(
        region: CaptureRegion, url: URL, fps: Int, cursor: Bool, codec: VideoCodec
    ) async throws {
        self.region = region
        self.url = url
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

    func testPauseAndResumeConfirmWithoutRecreatingTheCapture() async throws {
        let (model, capture, region, _) = try fixture()
        await model.beginRecording(region: region)
        model.togglePause()
        XCTAssertEqual(model.phase, .recording)
        XCTAssertTrue(model.pauseIsChanging)
        XCTAssertTrue(model.canControlRecording)
        try await settle { model.phase == .paused }
        XCTAssertFalse(model.pauseIsChanging)
        XCTAssertEqual(capture.pauseCalls, 1)
        model.togglePause()
        try await settle { model.phase == .recording }
        XCTAssertEqual(capture.resumeCalls, 1)
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

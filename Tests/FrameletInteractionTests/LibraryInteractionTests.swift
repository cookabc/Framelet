import AppKit
import Carbon
import FrameletCore
import XCTest

@testable import Framelet

@MainActor
final class LibraryInteractionTests: XCTestCase {
    func testDeletingCurrentClipClearsPreviewAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        let trash = root.appendingPathComponent("trash.mp4")
        let model = RecorderModel(libraryURL: library) { try FileManager.default.moveItem(at: $0, to: trash) }
        let file = library.appendingPathComponent("test.mp4")
        try Data([1]).write(to: file)
        let clip = RecordedClip(url: file, date: Date())
        model.clips = [clip]
        model.selected = clip
        model.duration = 10
        model.deleteClip(clip)
        XCTAssertTrue(model.clips.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.player)
        XCTAssertEqual(model.duration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
    }

    func testBusyOrFailedDeletionPreservesSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let model = RecorderModel(libraryURL: root) { _ in
            calls += 1
            throw CocoaError(.fileWriteNoPermission)
        }
        let file = root.appendingPathComponent("test.mp4")
        try Data([1]).write(to: file)
        let clip = RecordedClip(url: file, date: Date())
        model.clips = [clip]
        model.selected = clip
        model.phase = .recording
        model.deleteClip(clip)
        XCTAssertEqual(calls, 0)
        model.phase = .idle
        model.deleteClip(clip)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.selected, clip)
        XCTAssertEqual(model.clips, [clip])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testClipTitleKeepsAmPmSoAnAfternoonRecordingIsNotReadAsMorning() async throws {
        // 15:37 local is what the Chinese-only build rendered as "03:37", which reads as the middle
        // of the night and as a duration beside the player's own mm:ss readout.
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 10
        components.hour = 15
        components.minute = 37
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        let clip = RecordedClip(url: URL(fileURLWithPath: "/tmp/clip.mp4"), date: date)

        XCTAssertTrue(clip.title.contains("PM"), "got \(clip.title)")
        XCTAssertTrue(clip.title.contains("3:37"), "got \(clip.title)")
    }

    func testRecordingSettingsSurviveRelaunchAndFallBackToDefaults() async throws {
        let suite = "FrameletSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = RecorderModel(libraryURL: root, defaults: defaults)
        XCTAssertEqual(first.fps, 30, "An untouched suite should start from the built-in defaults.")
        XCTAssertTrue(first.showsCursor)
        XCTAssertEqual(first.gifFPS, 15)
        XCTAssertEqual(first.gifWidth, 960)
        XCTAssertEqual(first.countdownSeconds, 3)
        XCTAssertEqual(first.codec, .h264)

        first.fps = 60
        first.showsCursor = false
        first.gifFPS = 20
        first.gifWidth = 1280
        first.countdownSeconds = 10
        first.codec = .hevc

        let relaunched = RecorderModel(libraryURL: root, defaults: defaults)
        XCTAssertEqual(relaunched.fps, 60)
        XCTAssertFalse(relaunched.showsCursor)
        XCTAssertEqual(relaunched.gifFPS, 20)
        XCTAssertEqual(relaunched.gifWidth, 1280)
        XCTAssertEqual(relaunched.countdownSeconds, 10)
        XCTAssertEqual(relaunched.codec, .hevc)
    }

    func testRubbishStoredCountdownStillLeavesACountableDelay() async throws {
        let suite = "FrameletCountdownTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = RecorderModel(libraryURL: root, defaults: defaults)
        writer.countdownSeconds = 0

        // Reading a stored 0 back must not leave a zero-length "1...seconds" range, which traps.
        let relaunched = RecorderModel(libraryURL: root, defaults: defaults)
        XCTAssertEqual(relaunched.countdownSeconds, 1)
    }

    func testRubbishStoredRecordingSettingsFallBackIntoValidRanges() async throws {
        let suite = "FrameletSettingsClampTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = RecorderModel(libraryURL: root, defaults: defaults)
        writer.fps = 0
        writer.gifFPS = 999
        writer.gifWidth = 0

        // Values outside what the capture and GIF paths accept are clamped on read, never passed
        // through to fail later with a misleading message about the recording area or range.
        let relaunched = RecorderModel(libraryURL: root, defaults: defaults)
        XCTAssertEqual(relaunched.fps, 1)
        XCTAssertEqual(relaunched.gifFPS, 30)
        XCTAssertEqual(relaunched.gifWidth, 64)
    }

    func testRecoveryJoinsLegacySessionsAndReportsWhatItDiscards() async throws {
        let suite = "FrameletRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let small = try await makeRecoverySegment(in: scratch)
        let wide = try await makeRecoverySegment(in: scratch, width: 320)

        // A take recorded by an older build sits in the legacy container with two joinable segments.
        let legacyContainer = library.appendingPathComponent(
            RecordingLibrary.legacySessionFolderName, isDirectory: true)
        let legacySession = legacyContainer.appendingPathComponent("legacy-take", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySession, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: small, to: legacySession.appendingPathComponent("segment-a.mp4"))
        try FileManager.default.copyItem(
            at: small, to: legacySession.appendingPathComponent("segment-b.mp4"))
        try stamp(legacySession.appendingPathComponent("segment-a.mp4"), at: 1_000)
        try stamp(legacySession.appendingPathComponent("segment-b.mp4"), at: 2_000)

        // A current session that holds nothing usable.
        let junkSession = RecordingLibrary.newSessionURL(in: library)
        try FileManager.default.createDirectory(at: junkSession, withIntermediateDirectories: true)
        try Data().write(to: junkSession.appendingPathComponent("empty.mp4"))

        // A session whose segments cannot be joined stays on disk for the next launch.
        let stuckSession = RecordingLibrary.newSessionURL(in: library)
        try FileManager.default.createDirectory(at: stuckSession, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: wide, to: stuckSession.appendingPathComponent("segment-a.mp4"))
        try FileManager.default.copyItem(
            at: small, to: stuckSession.appendingPathComponent("segment-b.mp4"))
        try stamp(stuckSession.appendingPathComponent("segment-a.mp4"), at: 3_000)
        try stamp(stuckSession.appendingPathComponent("segment-b.mp4"), at: 4_000)

        let model = RecorderModel(libraryURL: library, defaults: defaults)
        await model.recoverUnfinishedSessions()

        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(
            model.notice,
            "Recovered 1 unfinished recording; 1 unfinished recording could not be joined;"
                + " the segments remain in the Unfinished folder; 1 that held nothing usable was discarded")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyContainer.path),
            "A legacy container emptied by recovery must be pruned.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: junkSession.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuckSession.path))
    }

    private func stamp(_ url: URL, at seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    func testEveryShortcutCandidateStaysOutOfTheWayOfOrdinaryAppMenus() async {
        XCTAssertEqual(RecorderShortcuts.captureKey, UInt32(kVK_ANSI_R))
        XCTAssertEqual(RecorderShortcuts.pauseKey, UInt32(kVK_ANSI_P))
        XCTAssertGreaterThan(
            RecorderShortcuts.modifierSets.count, 1,
            "Another app owning a combination needs somewhere to fall back to.")
        for set in RecorderShortcuts.modifierSets {
            // These are registered globally and exclusively, so a bare Command combination would be
            // taken away from every app: Command always comes with at least one more modifier.
            XCTAssertNotEqual(set.modifiers & UInt32(cmdKey), 0)
            XCTAssertGreaterThanOrEqual(set.modifiers.nonzeroBitCount, 2)
            // Control-Option-R belongs to Rectangle, so the two never appear together.
            XCTAssertNotEqual(
                set.modifiers & UInt32(controlKey | optionKey), UInt32(controlKey | optionKey),
                "\(set.captureLabel) collides with Rectangle")
        }
    }
}

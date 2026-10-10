import AppKit
import Carbon
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

        first.fps = 60
        first.showsCursor = false
        first.gifFPS = 20
        first.gifWidth = 1280

        let relaunched = RecorderModel(libraryURL: root, defaults: defaults)
        XCTAssertEqual(relaunched.fps, 60)
        XCTAssertFalse(relaunched.showsCursor)
        XCTAssertEqual(relaunched.gifFPS, 20)
        XCTAssertEqual(relaunched.gifWidth, 1280)
    }

    func testShortcutsStayOutOfTheWayOfOrdinaryAppMenus() async {
        XCTAssertEqual(RecorderShortcuts.captureKey, UInt32(kVK_ANSI_R))
        // Option-Control-R belongs to Rectangle, so Option must stay out of the combination.
        XCTAssertEqual(RecorderShortcuts.modifiers & UInt32(optionKey), 0)
        // Registering these globally and exclusively means a bare Command combination would be
        // taken from every app, so both Command and Control have to be present.
        XCTAssertNotEqual(RecorderShortcuts.modifiers & UInt32(cmdKey), 0)
        XCTAssertNotEqual(RecorderShortcuts.modifiers & UInt32(controlKey), 0)
    }
}

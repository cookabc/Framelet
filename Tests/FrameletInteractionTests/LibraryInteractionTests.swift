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

    func testShortcutsAvoidRectangleOptionControlR() async {
        XCTAssertEqual(RecorderShortcuts.captureKey, UInt32(kVK_ANSI_R))
        XCTAssertEqual(RecorderShortcuts.modifiers & UInt32(optionKey), 0)
        XCTAssertNotEqual(RecorderShortcuts.modifiers & UInt32(cmdKey), 0)
        XCTAssertNotEqual(RecorderShortcuts.modifiers & UInt32(shiftKey), 0)
    }
}

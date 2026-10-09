import XCTest

@testable import FrameletCore

final class RecordingLibraryTests: XCTestCase {
    func testTrashMovesOnlyLibraryOriginalAndPreservesExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let original = library.appendingPathComponent("clip.mp4")
        let exported = root.appendingPathComponent("exported.mp4")
        let trash = root.appendingPathComponent("recoverable.mp4")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.copyItem(at: original, to: exported)
        try RecordingLibrary.moveToTrash(original, in: library) {
            try FileManager.default.moveItem(at: $0, to: trash)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: trash), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: exported), Data([1, 2, 3]))
    }

    func testRejectsExternalFilesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("recordings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("outside.mp4")
        let link = library.appendingPathComponent("alias.mp4")
        try Data([9]).write(to: external)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        for file in [external, link, library.appendingPathComponent("notes.txt")] {
            XCTAssertThrowsError(
                try RecordingLibrary.moveToTrash(file, in: library) { _ in
                    XCTFail("Must not trash an unrelated file")
                })
        }
        XCTAssertEqual(try Data(contentsOf: external), Data([9]))
    }
}

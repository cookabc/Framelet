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

    func testUnfinishedSessionsAreOrderedAndSegmentsFollowCaptureOrder() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let older = RecordingLibrary.newSessionURL(in: library)
        let newer = RecordingLibrary.newSessionURL(in: library)
        for session in [newer, older] {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        }
        try stamp(older, at: 1_000)
        try stamp(newer, at: 2_000)
        // Compared by name: the directory listing reports /private/var where the fixture built /var.
        XCTAssertEqual(
            RecordingLibrary.unfinishedSessions(in: library).map(\.lastPathComponent),
            [older.lastPathComponent, newer.lastPathComponent])

        // A pause closes one segment and opens the next, so the second piece has to join second
        // even though its name carries no ordering. Zero-length debris and stray files are skipped.
        let first = newer.appendingPathComponent("segment-a.mp4")
        let second = newer.appendingPathComponent("segment-b.mp4")
        try Data([2]).write(to: first)
        try Data([1]).write(to: second)
        try Data().write(to: newer.appendingPathComponent("segment-empty.mp4"))
        try Data([3]).write(to: newer.appendingPathComponent("notes.txt"))
        try stamp(first, at: 10)
        try stamp(second, at: 20)
        XCTAssertEqual(
            RecordingLibrary.usableSegments(in: newer).map(\.lastPathComponent),
            [first.lastPathComponent, second.lastPathComponent])
    }

    func testRemoveSessionIsConfinedToTheLibraryAndClearsTheContainer() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("recordings", isDirectory: true)
        let session = RecordingLibrary.newSessionURL(in: library)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data([1]).write(to: session.appendingPathComponent("segment-a.mp4"))

        let outsider = root.appendingPathComponent("keep.txt")
        try Data([9]).write(to: outsider)
        RecordingLibrary.removeSession(outsider, in: library)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsider.path),
            "Only folders directly inside the session container may be deleted.")

        RecordingLibrary.removeSession(session, in: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: RecordingLibrary.sessionContainer(in: library).path),
            "An emptied container should not be left behind.")
    }

    func testEmptyContainerIsPrunedButOnlyOnceItIsEmpty() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("recordings", isDirectory: true)
        let container = RecordingLibrary.sessionContainer(in: library)

        let first = RecordingLibrary.newSessionURL(in: library)
        let second = RecordingLibrary.newSessionURL(in: library)
        for session in [first, second] {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        }

        RecordingLibrary.removeSession(first, in: library)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: container.path),
            "The container still holds another session, so it must stay.")

        RecordingLibrary.removeSession(second, in: library)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: container.path),
            "A take that succeeds on its own must not leave an empty container behind.")
    }

    func testLegacySessionFolderIsRecoveredAndPrunedLikeTheCurrentOne() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("recordings", isDirectory: true)
        let legacyContainer = library.appendingPathComponent(
            RecordingLibrary.legacySessionFolderName, isDirectory: true)
        let legacySession = legacyContainer.appendingPathComponent("old-take", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySession, withIntermediateDirectories: true)
        try Data([7]).write(to: legacySession.appendingPathComponent("segment-a.mp4"))
        try stamp(legacySession, at: 500)

        XCTAssertEqual(
            RecordingLibrary.unfinishedSessions(in: library).map(\.lastPathComponent), ["old-take"],
            "Sessions recorded by an older build must still be recovered.")

        let outsider = root.appendingPathComponent("keep.txt")
        try Data([9]).write(to: outsider)
        RecordingLibrary.removeSession(outsider, in: library)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsider.path),
            "The legacy container must not widen what removeSession may delete.")

        RecordingLibrary.removeSession(legacySession, in: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySession.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyContainer.path),
            "A legacy container emptied by recovery must not be left behind either.")
    }

    private func stamp(_ url: URL, at seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }
}

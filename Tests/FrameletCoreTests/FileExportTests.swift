import AVFoundation
import ImageIO
import XCTest

@testable import FrameletCore

final class FileExportTests: XCTestCase {
    func testVideoCopyReplacesOnlyAfterSuccess() throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mp4")
        let output = dir.appendingPathComponent("output.mp4")
        try Data("new video".utf8).write(to: source)
        try Data("old video".utf8).write(to: output)
        try FileExport.copyVideo(from: source, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data("new video".utf8))
        XCTAssertThrowsError(
            try FileExport.copyVideo(from: dir.appendingPathComponent("missing.mp4"), to: output))
        XCTAssertEqual(try Data(contentsOf: output), Data("new video".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }

    func testVideoCopySpansMultipleChunksWithoutCorruptingContent() throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("large.mp4")
        let output = dir.appendingPathComponent("output.mp4")
        let payload = Data((0..<(3 << 20)).map { UInt8($0 % 251) })
        try payload.write(to: source)
        try FileExport.copyVideo(from: source, to: output)
        XCTAssertEqual(try Data(contentsOf: output), payload)
    }

    func testCancelledVideoCopyNeverTruncatesTheDestinationOrLeavesStagingFiles() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("large.mp4")
        let output = dir.appendingPathComponent("output.mp4")
        let payload = Data((0..<(8 << 20)).map { UInt8($0 % 251) })
        try payload.write(to: source)
        try Data("existing".utf8).write(to: output)

        let task = Task { try FileExport.copyVideo(from: source, to: output) }
        task.cancel()
        do {
            try await task.value
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // Whether or not the cancel landed in time, the old file is never left half-written.
        let written = try Data(contentsOf: output)
        XCTAssertTrue(written == Data("existing".utf8) || written == payload)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
                $0.hasPrefix(".framelet-")
            }, "A cancelled copy must not leave its staging file behind.")
    }
}

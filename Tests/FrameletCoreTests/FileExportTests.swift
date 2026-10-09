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
}

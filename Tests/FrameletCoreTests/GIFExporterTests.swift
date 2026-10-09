import AVFoundation
import ImageIO
import XCTest

@testable import FrameletCore

final class GIFExporterTests: XCTestCase {
    func testGIFHasExpectedFramesSizeTimingAndLoop() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("clip.gif")
        try await GIFExporter.export(
            video: video, to: output,
            settings: GIFSettings(start: 0.5, duration: 1, fps: 10, maxWidth: 80), progress: { _ in })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 45)
        let global = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [String: Any])
        let globalGIF = try XCTUnwrap(global[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual(globalGIF[kCGImagePropertyGIFLoopCount as String] as? Int, 0)
        var duration = 0.0
        for index in 0..<10 {
            let props = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            duration += try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime as String] as? Double)
        }
        XCTAssertEqual(duration, 1, accuracy: 0.02)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 9, nil))
        XCTAssertNotEqual(
            samplePixel(first), samplePixel(last),
            "Frames should reflect changing source content, not a repeated still.")
    }

    func testInvalidRangePreservesExistingDestination() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("existing.gif")
        let existing = Data("keep this".utf8)
        try existing.write(to: output)
        do {
            try await GIFExporter.export(
                video: video, to: output,
                settings: GIFSettings(start: 1, duration: 8), progress: { _ in })
            XCTFail("Invalid range must fail")
        } catch { XCTAssertTrue(error is ExportError) }
        XCTAssertEqual(try Data(contentsOf: output), existing)
    }

    func testCancelledGIFPreservesDestinationAndRemovesStaging() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("existing.gif")
        let existing = Data("keep this".utf8)
        try existing.write(to: output)
        let task = Task {
            try await GIFExporter.export(
                video: video, to: output,
                settings: GIFSettings(start: 0, duration: 1), progress: { _ in })
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled export must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), existing)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
                $0.hasPrefix(".framelet-")
            })
    }
}

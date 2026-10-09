import AVFoundation
import ImageIO
import XCTest

@testable import FrameletCore

final class SessionAssemblerTests: XCTestCase {
    func testPausedSegmentsJoinWithoutGapAndBothRemainDecodable() async throws {
        let firstDir = try makeTestDirectory()
        let secondDir = try makeTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }
        let first = try await makeTestVideo(in: firstDir)
        let second = try await makeTestVideo(in: secondDir)
        let output = firstDir.appendingPathComponent("joined.mp4")
        try await SessionAssembler.assemble(segments: [first, second], to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (beforePause, _) = try await generator.image(at: CMTime(seconds: 1.8, preferredTimescale: 600))
        let (afterResume, _) = try await generator.image(at: CMTime(seconds: 2.2, preferredTimescale: 600))
        let (lastFrame, _) = try await generator.image(at: CMTime(seconds: 3.8, preferredTimescale: 600))
        XCTAssertNotEqual(samplePixel(beforePause), samplePixel(afterResume))
        XCTAssertEqual(samplePixel(beforePause), samplePixel(lastFrame))
        // Saving/restarting a take must not consume its source before the output succeeds.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let gif = firstDir.appendingPathComponent("joined.gif")
        try await GIFExporter.export(
            video: output, to: gif, settings: GIFSettings(start: 1.5, duration: 1, fps: 10, maxWidth: 80),
            progress: { _ in })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
    }

    func testMismatchedSegmentsPreserveExistingOutputAndSources() async throws {
        let firstDir = try makeTestDirectory()
        let secondDir = try makeTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }
        let first = try await makeTestVideo(in: firstDir)
        let second = try await makeTestVideo(in: secondDir, width: 200)
        let output = firstDir.appendingPathComponent("existing.mp4")
        let existing = Data("preserve".utf8)
        try existing.write(to: output)
        do {
            try await SessionAssembler.assemble(segments: [first, second], to: output)
            XCTFail("Mismatched dimensions must fail")
        } catch { XCTAssertTrue(error is SessionAssemblyError) }
        XCTAssertEqual(try Data(contentsOf: output), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSingleSegmentAndCancelledAssembly() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("take.mp4")
        try await SessionAssembler.assemble(segments: [source], to: output)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        let old = try Data(contentsOf: output)
        let task = Task { try await SessionAssembler.assemble(segments: [source, source], to: output) }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled assembly must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), old)
    }
}

import AVFoundation
import XCTest

@testable import FrameletCore

final class VideoExporterTests: XCTestCase {
    func testTrimSavesSelectedTimeRangeWithoutChangingOriginal() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await makeTestVideo(in: root)
        let original = try Data(contentsOf: video)
        let output = root.appendingPathComponent("trim.mp4")
        try await VideoExporter.export(video: video, to: output, start: 0.5, duration: 1)
        XCTAssertEqual(try Data(contentsOf: video), original)
        let asset = AVURLAsset(url: output)
        let length = try await asset.load(.duration).seconds
        XCTAssertEqual(length, 1, accuracy: 0.051)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 90))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let (last, _) = try await generator.image(at: CMTime(seconds: 0.9, preferredTimescale: 600))
        XCTAssertNotEqual(samplePixel(first), samplePixel(last))
    }

    func testFullLengthExportPreservesBytes() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await makeTestVideo(in: root)
        let output = root.appendingPathComponent("copy.mp4")
        try await VideoExporter.export(video: video, to: output, start: 0, duration: 2)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: video))
    }

    func testInvalidRangeAndCancelledExportLeaveDestinationUntouched() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await makeTestVideo(in: root)
        let output = root.appendingPathComponent("existing.mp4")
        let original = Data("Existing user file".utf8)
        try original.write(to: output)
        for range in [(-1.0, 1.0), (0.0, 0.0), (1.5, 1.0), (Double.nan, 1.0)] {
            do {
                try await VideoExporter.export(video: video, to: output, start: range.0, duration: range.1)
                XCTFail("Invalid range must fail")
            } catch { XCTAssertTrue(error is VideoExportError) }
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await VideoExporter.export(video: video, to: output, start: 0.5, duration: 1)
        }
        do {
            try await task.value
            XCTFail("Cancelled export must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix(".framelet-")
            })
    }

    func testCannotOverwriteOriginalOrItsAliases() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try await makeTestVideo(in: root)
        let original = try Data(contentsOf: video)
        let hard = root.appendingPathComponent("hard.mp4")
        let symbolic = root.appendingPathComponent("symbolic.mp4")
        try FileManager.default.linkItem(at: video, to: hard)
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: video)
        for destination in [video, hard, symbolic] {
            do {
                try await VideoExporter.export(video: video, to: destination, start: 0.5, duration: 1)
                XCTFail("Original and aliases must not be overwritten")
            } catch { XCTAssertTrue(error is VideoExportError) }
        }
        XCTAssertEqual(try Data(contentsOf: video), original)
    }
}

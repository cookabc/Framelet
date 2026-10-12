import AVFoundation
import ImageIO
import XCTest

@testable import FrameletCore

final class GIFExporterTests: XCTestCase {
    private func source(_ output: URL) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
    }

    func testGIFHasExpectedFramesSizeTimingAndLoop() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("clip.gif")
        try await GIFExporter.export(
            video: video, to: output,
            settings: GIFSettings(start: 0.5, duration: 1, fps: 10, maxWidth: 80), progress: { _ in })
        let source = try source(output)
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 45)
        let props = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [String: Any])
        let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount as String] as? Int, 0)
        var duration = 0.0
        for index in 0..<10 {
            let props = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            duration += try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
        }
        XCTAssertEqual(duration, 1, accuracy: 0.005)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 9, nil))
        XCTAssertNotEqual(samplePixel(first), samplePixel(last))
    }

    func testFlatDecodedColorsRemainCloseWithEitherDitherSetting() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.maximumSize = CGSize(width: 80, height: 80)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (reference, _) = try await generator.image(at: .zero)
        let expected = samplePixel(reference)
        for dither in [false, true] {
            let output = dir.appendingPathComponent("flat-\(dither).gif")
            try await GIFExporter.export(
                video: video, to: output,
                settings: GIFSettings(start: 0, duration: 0.5, fps: 10, maxWidth: 80, dither: dither),
                progress: { _ in })
            let source = try source(output)
            XCTAssertEqual(CGImageSourceGetCount(source), 5)
            for index in 0..<5 {
                let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                let actual = samplePixel(frame)
                for channel in 0..<3 {
                    XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 4)
                }
            }
        }
    }

    func testDitheredExportCrossesAContentChange() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("dithered.gif")
        try await GIFExporter.export(
            video: video, to: output,
            settings: GIFSettings(start: 0.9, duration: 1, fps: 10, maxWidth: 80, dither: true),
            progress: { _ in })
        let source = try source(output)
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 9, nil))
        XCTAssertGreaterThan(samplePixel(first)[0], samplePixel(last)[0])
        XCTAssertLessThan(samplePixel(first)[2], samplePixel(last)[2])
    }

    func testFractionalFrameDelaysDoNotAccumulateTimingError() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        for fps in [15, 30] {
            let output = dir.appendingPathComponent("timing-\(fps).gif")
            try await GIFExporter.export(
                video: video, to: output,
                settings: GIFSettings(start: 0, duration: 1, fps: fps, maxWidth: 80), progress: { _ in })
            let source = try source(output)
            var duration = 0.0
            for index in 0..<CGImageSourceGetCount(source) {
                let props = try XCTUnwrap(
                    CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
                let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary as String] as? [String: Any])
                duration += try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
            }
            XCTAssertEqual(duration, 1, accuracy: 0.005)
        }
    }

    func testInvalidSettingsAndRangesPreserveExistingDestination() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let output = dir.appendingPathComponent("existing.gif")
        let existing = Data("keep this".utf8)
        try existing.write(to: output)
        for settings in [
            GIFSettings(start: 1, duration: 8), GIFSettings(start: .nan, duration: 1),
            GIFSettings(start: 0, duration: 1, fps: 0), GIFSettings(start: 0, duration: 1, maxWidth: 8),
        ] {
            do {
                try await GIFExporter.export(video: video, to: output, settings: settings, progress: { _ in })
                XCTFail("Invalid settings must fail")
            } catch { XCTAssertTrue(error is ExportError) }
            XCTAssertEqual(try Data(contentsOf: output), existing)
        }
    }

    func testGIFCannotOverwriteSourceThroughALink() async throws {
        let dir = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await makeTestVideo(in: dir)
        let original = try Data(contentsOf: video)
        let link = dir.appendingPathComponent("source.gif")
        try FileManager.default.linkItem(at: video, to: link)
        do {
            try await GIFExporter.export(
                video: video, to: link,
                settings: GIFSettings(start: 0, duration: 0.5), progress: { _ in })
            XCTFail("An alias to the original must be rejected")
        } catch { XCTAssertTrue(error is ExportError) }
        XCTAssertEqual(try Data(contentsOf: video), original)
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
                settings: GIFSettings(start: 0, duration: 1),
                progress: { value in
                    if value >= 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
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

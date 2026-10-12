import AVFoundation
import XCTest

@testable import FrameletCore

final class CroppedVideoWriterTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 100.0
        func now() -> Double { lock.withLock { value } }
        func set(_ time: Double) { lock.withLock { value = time } }
    }

    private func displayFrame() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 400, 200, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<200 {
            for x in 0..<400 {
                let offset = y * rowBytes + x * 4
                bytes[offset] = y >= 100 ? 240 : 10
                bytes[offset + 1] = y < 100 && x >= 200 ? 240 : 10
                bytes[offset + 2] = y < 100 && x < 200 ? 240 : 10
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private func writer(
        in root: URL, clock: Clock, codec: VideoCodec = .h264
    ) throws -> CroppedVideoWriter {
        try CroppedVideoWriter(
            url: root.appendingPathComponent("take-\(UUID().uuidString).mp4"),
            source: CGRect(x: 100, y: 0, width: 100, height: 50),
            displaySize: CGSize(width: 200, height: 100), outputSize: CGSize(width: 100, height: 50),
            fps: 30, codec: codec,
            onFailure: { XCTFail("\($0)") }, uptime: { clock.now() })
    }

    private func append(_ writer: CroppedVideoWriter, buffer: CVPixelBuffer, at time: Double, clock: Clock)
        async throws
    {
        clock.set(time)
        for _ in 0..<200 {
            if writer.append(buffer, at: CMTime(seconds: time, preferredTimescale: 60000)) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The test encoder did not accept a frame at \(time)")
    }

    func testRetinaCropEncodesOnlySelectedPixelsAtRequestedSize() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let buffer = try displayFrame()
        for (index, source) in [
            CGRect(x: 100, y: 0, width: 100, height: 50),
            CGRect(x: 100, y: 50, width: 100, height: 50),
        ].enumerated() {
            let started = expectation(description: "First encoded frame \(index)")
            let writer = try CroppedVideoWriter(
                url: root.appendingPathComponent("crop-\(index).mp4"), source: source,
                displaySize: CGSize(width: 200, height: 100), outputSize: CGSize(width: 80, height: 40),
                fps: 30, onStarted: { started.fulfill() }, onFailure: { XCTFail("\($0)") })
            writer.append(buffer, at: CMTime(seconds: 100, preferredTimescale: 600))
            writer.append(buffer, at: CMTime(seconds: 99, preferredTimescale: 600))
            writer.append(buffer, at: CMTime(seconds: 100, preferredTimescale: 600))
            await fulfillment(of: [started], timeout: 3)
            let url = try await writer.finish()
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            let (frame, _) = try await generator.image(at: .zero)
            XCTAssertEqual(frame.width, 80)
            XCTAssertEqual(frame.height, 40)
            let pixel = samplePixel(frame)
            XCTAssertLessThan(pixel[0], 60)
            XCTAssertGreaterThan(pixel[index == 0 ? 1 : 2], 180)
            XCTAssertLessThan(pixel[index == 0 ? 2 : 1], 60)
        }
    }

    func testStaticTailAndRepeatedFinishShareTheSameFile() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let writer = try writer(in: root, clock: clock)
        try await append(writer, buffer: try displayFrame(), at: 100, clock: clock)
        clock.set(103)
        async let first = writer.finish()
        async let second = writer.finish()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        let later = try await writer.finish()
        XCTAssertEqual(a, later)
        let duration = try await AVURLAsset(url: a).load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.04)
    }

    func testStopWhilePausedKeepsTheStaticActiveTailButNotThePause() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let writer = try writer(in: root, clock: clock)
        try await append(writer, buffer: try displayFrame(), at: 100, clock: clock)
        clock.set(104)
        await writer.pause()
        clock.set(124)
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.04)
    }

    func testResumeWithoutNewFramesPreservesActiveTimeOnBothSides() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let writer = try writer(in: root, clock: clock)
        try await append(writer, buffer: try displayFrame(), at: 100, clock: clock)
        clock.set(103)
        await writer.pause()
        clock.set(113)
        await writer.resume()
        clock.set(117)
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 7, accuracy: 0.04)
    }

    func testMultiplePausesDoNotDoubleCountOffsetsOrRegressTimestamps() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let writer = try writer(in: root, clock: clock)
        let buffer = try displayFrame()
        try await append(writer, buffer: buffer, at: 100, clock: clock)
        try await append(writer, buffer: buffer, at: 101, clock: clock)
        clock.set(102)
        await writer.pause()
        clock.set(105)
        XCTAssertFalse(writer.append(buffer, at: CMTime(seconds: 105, preferredTimescale: 60000)))
        clock.set(112)
        await writer.resume()
        try await append(writer, buffer: buffer, at: 113, clock: clock)
        clock.set(114)
        await writer.pause()
        clock.set(134)
        await writer.resume()
        try await append(writer, buffer: buffer, at: 135, clock: clock)
        clock.set(136)
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.04)
        let reader = try AVAssetReader(asset: AVURLAsset(url: url))
        let asset = reader.asset
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderTrackOutput(
            track: try XCTUnwrap(tracks.first),
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(sample.presentationTimeStamp.seconds)
        }
        XCTAssertEqual(times.count, 4)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testNoFramesAndInvalidGeometryFailExplicitly() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = CGSize(width: 100, height: 50)
        let writer = try CroppedVideoWriter(
            url: root.appendingPathComponent("empty.mp4"), source: CGRect(origin: .zero, size: size),
            displaySize: size, outputSize: size, fps: 30)
        do {
            _ = try await writer.finish()
            XCTFail("Empty capture must not succeed")
        } catch {}
        do {
            _ = try await writer.finish()
            XCTFail("Empty finish result is shared")
        } catch {}
        XCTAssertThrowsError(
            try CroppedVideoWriter(
                url: root.appendingPathComponent("invalid.mp4"),
                source: CGRect(x: 90, y: 0, width: 30, height: 50),
                displaySize: size, outputSize: size, fps: 30))
    }

    func testSettingsOutsideTheSupportedRangeAreNamedAsSuch() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = CGSize(width: 100, height: 50)
        do {
            _ = try CroppedVideoWriter(
                url: root.appendingPathComponent("fps.mp4"), source: CGRect(origin: .zero, size: size),
                displaySize: size, outputSize: size, fps: 0)
            XCTFail("Invalid FPS must fail")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 2)
            XCTAssertEqual(
                error.localizedDescription, "The recording settings are outside the supported range.")
        }
        XCTAssertThrowsError(
            try CroppedVideoWriter(
                url: root.appendingPathComponent("odd.mp4"), source: CGRect(origin: .zero, size: size),
                displaySize: size, outputSize: CGSize(width: 101, height: 50), fps: 30))
    }
    func testHEVCStillRecordsTheChosenCodecAfterAPause() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let writer = try writer(in: root, clock: clock, codec: .hevc)
        let buffer = try displayFrame()
        try await append(writer, buffer: buffer, at: 100, clock: clock)
        clock.set(101)
        await writer.pause()
        clock.set(109)
        await writer.resume()
        try await append(writer, buffer: buffer, at: 110, clock: clock)
        clock.set(111)
        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let formats = try await XCTUnwrap(tracks.first).load(.formatDescriptions)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_HEVC)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.04)
        let generator = AVAssetImageGenerator(asset: asset)
        _ = try await generator.image(at: .zero)
    }
}

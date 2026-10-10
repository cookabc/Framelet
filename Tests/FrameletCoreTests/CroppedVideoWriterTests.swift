import AVFoundation
import XCTest

@testable import FrameletCore

final class CroppedVideoWriterTests: XCTestCase {
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
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<200 {
            for x in 0..<400 {
                let offset = y * stride + x * 4
                // Top-left red, top-right green, bottom blue: flipping or moving the crop fails visibly.
                bytes[offset] = y >= 100 ? 240 : 10
                bytes[offset + 1] = y < 100 && x >= 200 ? 240 : 10
                bytes[offset + 2] = y < 100 && x < 200 ? 240 : 10
                bytes[offset + 3] = 255
            }
        }
        return buffer
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
            // Old and duplicate samples cannot start the clock twice or corrupt the writer timeline.
            writer.append(buffer, at: CMTime(seconds: 99, preferredTimescale: 600))
            writer.append(buffer, at: CMTime(seconds: 100, preferredTimescale: 600))
            await fulfillment(of: [started], timeout: 3)
            let url = try await writer.finish()
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            let (frame, _) = try await generator.image(at: .zero)
            XCTAssertEqual(frame.width, 80)
            XCTAssertEqual(frame.height, 40)
            let pixel = samplePixel(frame)
            XCTAssertLessThan(pixel[0], 60, "The red pixels outside the selection must not be encoded")
            XCTAssertGreaterThan(pixel[index == 0 ? 1 : 2], 180)
            XCTAssertLessThan(pixel[index == 0 ? 2 : 1], 60, "The selected vertical half must be correct")
        }
    }

    func testStaticDisplayLastFrameLastsUntilStop() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CroppedVideoWriter(
            url: root.appendingPathComponent("static.mp4"),
            source: CGRect(x: 100, y: 0, width: 100, height: 50),
            displaySize: CGSize(width: 200, height: 100), outputSize: CGSize(width: 100, height: 50), fps: 30)
        writer.append(try displayFrame(), at: CMTime(seconds: 200, preferredTimescale: 600))
        try await Task.sleep(for: .milliseconds(300))
        let url = try await writer.finish()
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertGreaterThanOrEqual(duration, 0.29)
        XCTAssertLessThan(duration, 1)
        do {
            _ = try await writer.finish()
            XCTFail("Finishing twice must report an error instead of hanging")
        } catch {}
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
            XCTFail("An empty capture must not be reported as a saved recording")
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
        // An out-of-range frame rate is a settings problem, not a geometry one; the message must
        // not send the user hunting for a display that is fine.
        do {
            _ = try CroppedVideoWriter(
                url: root.appendingPathComponent("fps.mp4"), source: CGRect(origin: .zero, size: size),
                displaySize: size, outputSize: size, fps: 0)
            XCTFail("A frame rate outside 1...240 must be rejected")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 2)
            XCTAssertEqual(
                error.localizedDescription, "The recording settings are outside the supported range.")
        }
        do {
            _ = try CroppedVideoWriter(
                url: root.appendingPathComponent("odd.mp4"), source: CGRect(origin: .zero, size: size),
                displaySize: size, outputSize: CGSize(width: 101, height: 50), fps: 30)
            XCTFail("Odd output dimensions must be rejected")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 2)
        }
    }
}

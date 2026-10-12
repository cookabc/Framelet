import AVFoundation
import CoreImage
import XCTest

@testable import FrameletCore

/// Covers the mapping from desktop points to encoded pixels, which is what decides whether an
/// annotation lands where it was drawn.
final class CaptureProjectionTests: XCTestCase {
    func testAreaCropMapsPointsInsideTheSelectionAndRejectsPointsOutside() {
        // A 1000x800 display, 200x100 area at (300, 500), encoded at 400x200.
        let projection = CaptureProjection(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            source: CGRect(x: 300, y: 200, width: 200, height: 100),
            bufferSize: CGSize(width: 1000, height: 800),
            outputSize: CGSize(width: 400, height: 200))
        // Top-left corner of the area: AppKit y counts up, so the area's top edge is 500+100=600.
        XCTAssertEqual(projection.outputPoint(CGPoint(x: 300, y: 600)), CGPoint(x: 0, y: 0))
        // Bottom-right corner.
        XCTAssertEqual(projection.outputPoint(CGPoint(x: 500, y: 500)), CGPoint(x: 400, y: 200))
        // Middle.
        let middle = try? XCTUnwrap(projection.outputPoint(CGPoint(x: 400, y: 550)))
        XCTAssertEqual(middle?.x ?? -1, 200, accuracy: 0.01)
        XCTAssertEqual(middle?.y ?? -1, 100, accuracy: 0.01)
        // Just outside the area on any side must not paint at all.
        XCTAssertNil(projection.outputPoint(CGPoint(x: 299, y: 550)))
        XCTAssertNil(projection.outputPoint(CGPoint(x: 400, y: 601)))
        XCTAssertNil(projection.outputPoint(CGPoint(x: 400, y: 499)))
        XCTAssertNil(projection.outputPoint(CGPoint(x: 501, y: 550)))
    }

    func testDisplayWithASecondScreenOffsetStillMapsToThePicture() {
        // The area sits on a second display placed to the left of the primary one.
        let projection = CaptureProjection(
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            source: CGRect(x: 900, y: 400, width: 400, height: 200),
            bufferSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 800, height: 400))
        // Top-left of the recorded area in global points.
        let topLeft = CGPoint(x: -1920 + 900, y: 0 + 680)
        XCTAssertEqual(projection.outputPoint(topLeft), CGPoint(x: 0, y: 0))
    }

    func testScaledBufferStillDividesOutExactly() {
        // A display big enough that the encoded size is capped: the buffer and the projection
        // scale by the same factor, so the mapping stays exact.
        let projection = CaptureProjection(
            frame: CGRect(x: 0, y: 0, width: 6000, height: 3000),
            source: CGRect(x: 0, y: 0, width: 6000, height: 3000),
            bufferSize: CGSize(width: 6000, height: 3000),
            outputSize: CGSize(width: 3840, height: 1920))
        let center = projection.outputPoint(CGPoint(x: 3000, y: 1500))
        XCTAssertEqual(center?.x ?? -1, 1920, accuracy: 0.01)
        XCTAssertEqual(center?.y ?? -1, 960, accuracy: 0.01)
    }
}

/// A window take records the window itself: the buffer shows only the window, so the crop is the
/// whole buffer and the surface is the window's own size. Getting this wrong was a real bug — the
/// crop was divided by the screen size while the buffer held only the window, which cut the picture
/// down to a fraction of the window and stretched it back up.
final class WindowCaptureGeometryTests: XCTestCase {
    func testAWindowSizedCropFillsTheBufferAndAFullWindowFrameEncodesWhole() async throws {
        let windowSize = CGSize(width: 900, height: 620)
        let outputSize = CaptureGeometry.pixelSize(points: windowSize, scale: 2)
        // Encode a frame whose content is a colour ramp: with the crop filling the buffer, the
        // encoded picture carries the whole ramp, not a corner of it scaled up.
        let buffer = try makeRampBuffer(width: Int(windowSize.width), height: Int(windowSize.height))
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CroppedVideoWriter(
            url: root.appendingPathComponent("window.mp4"),
            source: CGRect(origin: .zero, size: windowSize), displaySize: windowSize,
            outputSize: outputSize, fps: 30)
        writer.append(buffer, at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let url = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        XCTAssertEqual(size, outputSize)

        // The projection for this take maps the window's top-left to the picture's top-left and its
        // bottom-right to the picture's bottom-right, which is what places annotations correctly.
        let projection = CaptureProjection(
            frame: CGRect(origin: .zero, size: windowSize),
            source: CGRect(origin: .zero, size: windowSize), bufferSize: windowSize,
            outputSize: outputSize)
        XCTAssertEqual(
            projection.outputPoint(CGPoint(x: 0, y: windowSize.height)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(
            projection.outputPoint(CGPoint(x: windowSize.width, y: 0)),
            CGPoint(x: outputSize.width, y: outputSize.height))
    }

    /// A grey ramp left to right and black to white top to bottom, so a wrong crop or a wrong
    /// orientation shows up as the wrong corner colours.
    private func makeRampBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                let horizontal = UInt8(x * 255 / max(1, width - 1))
                let vertical = UInt8(y * 255 / max(1, height - 1))
                bytes[offset] = horizontal
                bytes[offset + 1] = vertical
                bytes[offset + 2] = 0
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }
}

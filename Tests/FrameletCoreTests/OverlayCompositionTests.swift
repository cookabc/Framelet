import AVFoundation
import XCTest

@testable import FrameletCore

/// Verifies that annotations and input feedback actually reach the encoded picture, in the right
/// place and the right way up. The coordinate flip between AppKit points and Core Graphics was
/// wrong once already: the marks were drawn mirrored top-to-bottom, which only a rendered frame
/// can catch, so these tests sample real pixels.
final class OverlayCompositionTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)

    private func whiteFrame() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let offset = y * stride + x * 4
                base[offset] = 250
                base[offset + 1] = 250
                base[offset + 2] = 250
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    private func render(_ effects: RecordingEffects, at time: Double) async throws -> CGImage {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try CroppedVideoWriter(
            url: root.appendingPathComponent("overlay.mp4"), source: CGRect(origin: .zero, size: size),
            displaySize: size, outputSize: size, fps: 30, effects: effects,
            globalFrame: CGRect(origin: .zero, size: size))
        writer.append(try whiteFrame(), at: CMTime(seconds: time, preferredTimescale: 600))
        try await Task.sleep(for: .milliseconds(200))
        let url = try await writer.finish()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)
        return image
    }

    /// Samples the picture straight from its top-left pixel space, which is the space the ink is
    /// drawn in and needs no axis conversion.
    private func pixel(_ image: CGImage, atPicture point: CGPoint) -> [UInt8] {
        let x = max(0, min(image.width - 1, Int(point.x)))
        let y = max(0, min(image.height - 1, Int(point.y)))
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return [0, 0, 0, 0]
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    func testPenStrokeLandsOnTheSideItWasDrawnOn() async throws {
        let effects = RecordingEffects()
        let id = effects.beginMark(stroke: .pen, at: CGPoint(x: 60, y: 60), colorIndex: 0, width: 4)
        for x in stride(from: 60, through: 340, by: 8) {
            effects.extendMark(id: id, to: CGPoint(x: CGFloat(x), y: 60))
        }
        effects.finishMark(id: id)
        let image = try await render(effects, at: 10)
        // The stroke was drawn 60 points above the bottom: red there, and untouched far above it.
        let onStroke = pixel(image, atPicture: CGPoint(x: 200, y: size.height - 60))
        let above = pixel(image, atPicture: CGPoint(x: 200, y: size.height - 240))
        XCTAssertGreaterThan(Int(onStroke[0]), 150, "The mark must be where it was drawn: \(onStroke)")
        XCTAssertLessThan(Int(onStroke[1]), 120)
        XCTAssertGreaterThan(Int(above[0]), 230, "The picture stays clean above the stroke: \(above)")
    }

    func testStrokesOutsideTheRecordedAreaAreNotPainted() async throws {
        let effects = RecordingEffects()
        // A stroke entirely outside the recorded rectangle: nothing may reach the picture.
        let id = effects.beginMark(stroke: .pen, at: CGPoint(x: 600, y: 600), colorIndex: 0, width: 4)
        effects.extendMark(id: id, to: CGPoint(x: 700, y: 700))
        effects.finishMark(id: id)
        let image = try await render(effects, at: 10)
        for point in [CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 150), CGPoint(x: 380, y: 280)] {
            let sample = pixel(image, atPicture: CGPoint(x: point.x, y: size.height - point.y))
            XCTAssertGreaterThan(Int(sample[0]), 230, "An off-area mark must not be painted: \(sample)")
        }
    }

    func testStaticScreenRefreshShowsNewMarksAndRemovesClearedMarks() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = RecordingEffects()
        let writer = try CroppedVideoWriter(
            url: root.appendingPathComponent("refresh.mp4"), source: CGRect(origin: .zero, size: size),
            displaySize: size, outputSize: size, fps: 30, effects: effects,
            globalFrame: CGRect(origin: .zero, size: size))
        let buffer = try whiteFrame()
        XCTAssertTrue(writer.append(buffer, at: CMTime(seconds: 100, preferredTimescale: 600)))
        let id = effects.beginMark(stroke: .pen, at: CGPoint(x: 60, y: 60), colorIndex: 0, width: 4)
        effects.extendMark(id: id, to: CGPoint(x: 340, y: 60))
        try await Task.sleep(for: .milliseconds(50))
        writer.refresh(buffer, at: CMTime(seconds: 101, preferredTimescale: 600))
        effects.clear()
        try await Task.sleep(for: .milliseconds(50))
        writer.refresh(buffer, at: CMTime(seconds: 102, preferredTimescale: 600))
        let url = try await writer.finish()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (drawn, _) = try await generator.image(at: CMTime(seconds: 1.1, preferredTimescale: 600))
        let (cleared, _) = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600))
        XCTAssertLessThan(Int(pixel(drawn, atPicture: CGPoint(x: 200, y: 240))[1]), 120)
        XCTAssertGreaterThan(Int(pixel(cleared, atPicture: CGPoint(x: 200, y: 240))[1]), 230)
    }

    func testNothingIsPaintedWhenTheTakeHasNoOverlays() async throws {
        let image = try await render(RecordingEffects(), at: 10)
        for point in [CGPoint(x: 20, y: 20), CGPoint(x: 200, y: 150), CGPoint(x: 380, y: 280)] {
            let sample = pixel(image, atPicture: CGPoint(x: point.x, y: size.height - point.y))
            XCTAssertGreaterThan(Int(sample[0]), 230, "A plain take stays untouched: \(sample)")
        }
    }
}

import AVFoundation
import CoreText
import XCTest

@testable import FrameletCore

final class SmallCaptureQualityTests: XCTestCase {
    private func detailFrame() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 320, 180, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(
            CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: 320, height: 180, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 16, to: 100, by: 2) {
            context.fill(CGRect(x: x, y: 100, width: 1, height: 60))
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "small text 0123456789",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                        gray: 0, alpha: 1),
                ]))
        context.textPosition = CGPoint(x: 110, y: 110)
        CTLineDraw(line, context)
        return buffer
    }

    func testOddSmallCropRetainsSinglePixelLinesForBothCodecs() async throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let buffer = try detailFrame()
        for codec in VideoCodec.allCases {
            let writer = try CroppedVideoWriter(
                url: root.appendingPathComponent("detail-\(codec.rawValue).mp4"),
                source: CGRect(x: 0, y: 0, width: 319, height: 179),
                displaySize: CGSize(width: 320, height: 180), outputSize: CGSize(width: 318, height: 178),
                fps: 30, codec: codec)
            XCTAssertTrue(writer.append(buffer, at: CMTime(seconds: 100, preferredTimescale: 600)))
            let url = try await writer.finish()
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            let (image, _) = try await generator.image(at: .zero)
            XCTAssertEqual(image.width, 318)
            XCTAssertEqual(image.height, 178)
            let bytes = try rgb(image)
            let row = 40
            for x in 20..<90 {
                let offset = (row * image.width + x) * 4
                let value = Int(bytes[offset])
                if x % 2 == 0 {
                    XCTAssertLessThan(value, 65, "\(codec): thin black line blurred at \(x): \(value)")
                } else {
                    XCTAssertGreaterThan(value, 190, "\(codec): thin white line blurred at \(x): \(value)")
                }
            }
            let darkTextPixels = (60..<85).reduce(0) { count, y in
                count + (110..<280).filter { bytes[(y * image.width + $0) * 4] < 100 }.count
            }
            XCTAssertGreaterThan(darkTextPixels, 200, "Small glyphs must survive encoding")
        }
    }

    private func rgb(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(
                CGContext(
                    data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

import CoreGraphics
import XCTest

@testable import FrameletCore

final class VideoPreviewGeometryTests: XCTestCase {
    func testSmallVideoDoesNotUpscaleOnStandardOrRetinaDisplay() {
        for scale: CGFloat in [1, 2] {
            let pixels = CGSize(width: 300, height: 160)
            let frame = VideoPreviewGeometry.frame(
                pixelSize: pixels, available: CGSize(width: 620, height: 400),
                backingScale: scale, sizing: .actualSize)
            XCTAssertEqual(frame.width * scale, pixels.width)
            XCTAssertEqual(frame.height * scale, pixels.height)
            XCTAssertEqual(frame.midX, 310, accuracy: 0.5 / scale)
            XCTAssertEqual(frame.midY, 200, accuracy: 0.5 / scale)
        }
    }

    func testFitWindowCanEnlargeButOriginalSizeCannot() {
        let pixels = CGSize(width: 300, height: 160)
        let available = CGSize(width: 600, height: 320)
        let actual = VideoPreviewGeometry.frame(
            pixelSize: pixels, available: available,
            backingScale: 2, sizing: .actualSize)
        let fit = VideoPreviewGeometry.frame(
            pixelSize: pixels, available: available,
            backingScale: 2, sizing: .fitWindow)
        XCTAssertEqual(actual.size, CGSize(width: 150, height: 80))
        XCTAssertEqual(fit.size, available)
    }

    func testLargeVideoShrinksToFitWithoutClippingOrStretching() {
        for sizing in VideoPreviewSizing.allCases {
            let frame = VideoPreviewGeometry.frame(
                pixelSize: CGSize(width: 3840, height: 2160),
                available: CGSize(width: 620, height: 250), backingScale: 2, sizing: sizing)
            XCTAssertLessThanOrEqual(frame.width, 620)
            XCTAssertLessThanOrEqual(frame.height, 250)
            XCTAssertEqual(frame.width / frame.height, 16.0 / 9, accuracy: 0.003)
            XCTAssertEqual((frame.minX * 2).rounded(), frame.minX * 2)
            XCTAssertEqual((frame.minY * 2).rounded(), frame.minY * 2)
        }
    }

    func testInvalidMetadataProducesNoFrameRatherThanUpscalingUnknownVideo() {
        XCTAssertEqual(
            VideoPreviewGeometry.frame(
                pixelSize: .zero, available: CGSize(width: 400, height: 300),
                backingScale: 2, sizing: .actualSize), .zero)
        XCTAssertEqual(
            VideoPreviewGeometry.frame(
                pixelSize: CGSize(width: 100, height: 50), available: .zero,
                backingScale: 2, sizing: .actualSize), .zero)
        XCTAssertEqual(
            VideoPreviewGeometry.frame(
                pixelSize: CGSize(width: CGFloat.nan, height: 50),
                available: CGSize(width: 400, height: 300), backingScale: 2, sizing: .fitWindow), .zero)
    }
}

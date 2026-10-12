import CoreGraphics
import XCTest

@testable import FrameletCore

final class ScreenVideoQualityTests: XCTestCase {
    func testSmallSelectionsHaveBitrateFloorForBothCodecs() {
        for codec in VideoCodec.allCases {
            XCTAssertEqual(
                ScreenVideoQuality.averageBitRate(
                    pixelSize: CGSize(width: 300, height: 160),
                    fps: 30, codec: codec), 2_000_000)
        }
    }

    func testBitrateScalesWithPixelCountAndFrameRateButHasBoundedCeiling() {
        let pixels = CGSize(width: 1920, height: 1080)
        let h264 = ScreenVideoQuality.averageBitRate(pixelSize: pixels, fps: 30, codec: .h264)
        XCTAssertEqual(h264, 15_552_000)
        XCTAssertEqual(ScreenVideoQuality.averageBitRate(pixelSize: pixels, fps: 60, codec: .h264), h264 * 2)
        XCTAssertLessThan(ScreenVideoQuality.averageBitRate(pixelSize: pixels, fps: 30, codec: .hevc), h264)
        XCTAssertEqual(
            ScreenVideoQuality.averageBitRate(
                pixelSize: CGSize(width: 8192, height: 8192),
                fps: 240, codec: .h264), 80_000_000)
    }
}

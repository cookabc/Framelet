import XCTest

@testable import FrameletCore

final class CaptureGeometryTests: XCTestCase {
    func testRetinaScreenUsesPointsAndFlipsY() {
        let rect = CaptureGeometry.sourceRect(
            selection: CGRect(x: 100, y: 200, width: 320, height: 180),
            screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(rect, CGRect(x: 100, y: 520, width: 320, height: 180))
        XCTAssertEqual(
            CaptureGeometry.pixelSize(points: rect!.size, scale: 2), CGSize(width: 640, height: 360))
    }

    func testDisplayLeftOfPrimaryAndAbovePrimary() {
        let screen = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        XCTAssertEqual(
            CaptureGeometry.sourceRect(
                selection: CGRect(x: -1800, y: 1000, width: 400, height: 200), screen: screen),
            CGRect(x: 120, y: 180, width: 400, height: 200))
    }

    func testClipsAtDisplayEdgesAndRejectsTinyRegions() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(
            CaptureGeometry.sourceRect(
                selection: CGRect(x: 900, y: 700, width: 200, height: 200), screen: screen),
            CGRect(x: 900, y: 0, width: 100, height: 100))
        XCTAssertNil(
            CaptureGeometry.sourceRect(selection: CGRect(x: 5, y: 5, width: 10, height: 10), screen: screen))
        XCTAssertNil(
            CaptureGeometry.sourceRect(
                selection: CGRect(x: 1200, y: 900, width: 100, height: 100), screen: screen))
    }

    func testEncoderDimensionsAreEvenAndBounded() {
        let size = CaptureGeometry.pixelSize(points: CGSize(width: 3001, height: 1999), scale: 2)
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertEqual(size.width / size.height, 3001.0 / 1999.0, accuracy: 0.002)
    }
}

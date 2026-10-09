import XCTest

@testable import FrameletCore

final class WindowSelectionTests: XCTestCase {

    func testWindowSelectionUsesFrontToBackOrder() {
        let front = WindowCandidate(
            id: 1, ownerPID: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Front")
        let obscured = WindowCandidate(
            id: 2, ownerPID: 20, frame: CGRect(x: 50, y: 50, width: 200, height: 100), title: "Behind")
        XCTAssertEqual(
            WindowSelection.hit(at: CGPoint(x: 100, y: 100), candidates: [front, obscured])?.id, 1)
        XCTAssertEqual(
            WindowSelection.hit(at: CGPoint(x: 100, y: 100), candidates: [obscured, front])?.id, 2)
        XCTAssertNil(WindowSelection.hit(at: CGPoint(x: 900, y: 900), candidates: [front, obscured]))
    }

    func testWindowCoordinatesOnExternalScreenAboveAndLeft() {
        XCTAssertEqual(
            WindowSelection.appKitRect(
                fromQuartz: CGRect(x: -1920, y: -480, width: 800, height: 600), primaryTop: 900),
            CGRect(x: -1920, y: 780, width: 800, height: 600))
    }
}

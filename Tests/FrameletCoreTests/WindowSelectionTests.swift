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

    func testMenuLevelWindowsAreAcceptedOnlyFromOrdinaryApps() {
        // A measured menu bar dropdown sits at layer 101, and a status item's pop-up at 24–25.
        XCTAssertTrue(WindowSelection.acceptsMenu(layer: 101, owner: "Some Menu Bar App"))
        XCTAssertTrue(WindowSelection.acceptsMenu(layer: 25, owner: "Some Menu Bar App"))
        // The menu bar, Dock and window manager are menu-level too, but are chrome, not content.
        XCTAssertFalse(WindowSelection.acceptsMenu(layer: 24, owner: "Window Server"))
        XCTAssertFalse(WindowSelection.acceptsMenu(layer: 20, owner: "Dock"))
        XCTAssertFalse(WindowSelection.acceptsMenu(layer: 19, owner: "WindowManager"))
        // Above the menu level is the overlay and the cursor, which must never be chosen.
        XCTAssertFalse(WindowSelection.acceptsMenu(layer: 1000, owner: "Some Menu Bar App"))
        // Ordinary windows are not menus; the existing window path handles them.
        XCTAssertFalse(WindowSelection.acceptsMenu(layer: 0, owner: "Some Menu Bar App"))
    }

    func testMenuCandidateIsDistinguishedFromAnOrdinaryWindow() {
        let menu = WindowCandidate(
            id: 7, ownerPID: 9, frame: CGRect(x: 100, y: 100, width: 80, height: 200), title: "App · Menu",
            isMenu: true)
        let window = WindowCandidate(
            id: 1, ownerPID: 10, frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Window")
        XCTAssertTrue(menu.isMenu)
        XCTAssertFalse(window.isMenu, "Ordinary windows default to the window path.")
        XCTAssertEqual(WindowSelection.hit(at: CGPoint(x: 120, y: 150), candidates: [menu, window])?.id, 7)
    }
}

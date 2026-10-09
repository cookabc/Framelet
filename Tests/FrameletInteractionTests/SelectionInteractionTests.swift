import AppKit
import FrameletCore
import XCTest

@testable import Framelet

@MainActor
final class SelectionInteractionTests: XCTestCase {
    private func fixture(origin: CGPoint = .zero) -> (SelectionPanel, SelectionView) {
        _ = NSApplication.shared
        let panel = SelectionPanel(frame: CGRect(x: origin.x, y: origin.y, width: 800, height: 600))
        let view = SelectionView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.screenOrigin = origin
        view.candidates = [
            WindowCandidate(
                id: 42, ownerPID: 123,
                frame: CGRect(x: origin.x, y: origin.y, width: 800, height: 600),
                title: "Maximized test window")
        ]
        panel.contentView = view
        return (panel, view)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, panel: NSWindow, clicks: Int = 1)
        -> NSEvent
    {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
            clickCount: clicks, pressure: 1)!
    }

    func testPanelDoesNotActivateAppOrJoinMainWindowCycle() async {
        let (panel, view) = fixture()
        defer { panel.close() }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isMovable)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testFirstClickSelectsWindowWithoutPriorMouseMove() async {
        let (panel, view) = fixture(origin: CGPoint(x: -1920, y: 300))
        defer { panel.close() }
        var selected: UInt32?
        view.onWindowSelect = { selected = $0.id }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 300), panel: panel))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 402, y: 301), panel: panel))
        XCTAssertEqual(selected, 42)
    }

    func testDoubleClickCommitsOnceIncludingAtWindowTitleBar() async {
        let (panel, view) = fixture()
        defer { panel.close() }
        var confirmations = 0
        view.onWindowSelect = { _ in confirmations += 1 }
        for count in [1, 2] {
            view.mouseDown(
                with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 585), panel: panel, clicks: count))
            view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 585), panel: panel, clicks: count))
        }
        XCTAssertEqual(confirmations, 1)
    }

    func testDragSelectsRegionRatherThanHoveredWindow() async {
        let (panel, view) = fixture()
        defer { panel.close() }
        var selection: CGRect?
        view.onSelect = { selection = $0 }
        view.onWindowSelect = { _ in XCTFail("A drag must not select the hovered window") }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), panel: panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 250), panel: panel))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 250), panel: panel))
        XCTAssertEqual(selection, CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testReturnConfirmsHoveredWindow() async {
        let (panel, view) = fixture()
        defer { panel.close() }
        var selected: UInt32?
        view.onWindowSelect = { selected = $0.id }
        view.updateHover(globalPoint: CGPoint(x: 400, y: 300))
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: event)
        XCTAssertEqual(selected, 42)
    }

    func testHighlightedInteriorRetainsMouseHitSurface() async throws {
        let (panel, view) = fixture()
        defer { panel.close() }
        view.updateHover(globalPoint: CGPoint(x: 400, y: 300))
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        let center = try XCTUnwrap(bitmap.colorAt(x: 400, y: 300))
        XCTAssertGreaterThan(
            center.alphaComponent, 0.01, "The selected interior must not become a click-through hole.")
        XCTAssertLessThan(center.alphaComponent, 0.05, "The selected window should remain visually clear.")
    }
}

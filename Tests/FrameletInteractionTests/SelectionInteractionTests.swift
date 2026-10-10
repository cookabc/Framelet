import AppKit
import Carbon
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
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(view.needsPanelToBecomeKey)
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

    func testShowingAndClickingOverlayKeepsExistingKeyWindow() async throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        let host = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let (panel, view) = fixture()
        defer {
            panel.close()
            host.close()
            application.setActivationPolicy(previousPolicy)
        }
        host.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        guard host.isKeyWindow else {
            throw XCTSkip("This test host cannot acquire keyboard focus in the current WindowServer session")
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 300), panel: panel))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(host.isKeyWindow, "The selector must leave the target's keyboard focus alone")
    }

    func testSelectionKeysReleaseReturnAfterStopAndDeinit() async throws {
        _ = NSApplication.shared
        var keys: SelectionKeys? = SelectionKeys()
        XCTAssertTrue(keys!.start { _ in }.contains(.confirm))
        var competing: EventHotKeyRef?
        func registerReturn() -> OSStatus {
            RegisterEventHotKey(
                UInt32(kVK_Return), 0, EventHotKeyID(signature: 0x5445_5354, id: 1),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &competing)
        }
        defer { if let competing { UnregisterEventHotKey(competing) } }
        XCTAssertEqual(registerReturn(), OSStatus(eventHotKeyExistsErr))
        keys?.stop()
        XCTAssertEqual(registerReturn(), noErr)
        XCTAssertFalse(keys!.start { _ in }.contains(.confirm), "An occupied key must not be advertised")
        if let competing { UnregisterEventHotKey(competing) }
        competing = nil
        XCTAssertTrue(keys!.start { _ in }.contains(.confirm))
        keys = nil
        XCTAssertEqual(registerReturn(), noErr, "Leaving selection must restore Return to other apps")
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

    func testMenuConfirmationUsesClippedAreaAndNeverWindowCapture() async {
        let (panel, view) = fixture(origin: CGPoint(x: -800, y: 600))
        defer { panel.close() }
        view.candidates = [
            WindowCandidate(
                id: 99, ownerPID: 456, frame: CGRect(x: -820, y: 1000, width: 250, height: 300),
                title: "Test Menu", isMenu: true)
        ]
        var regions: [CGRect] = []
        view.onSelect = { regions.append($0) }
        view.onWindowSelect = { _ in XCTFail("Transient menus must use display pixels") }
        view.updateHover(globalPoint: CGPoint(x: -700, y: 1100))
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: event)
        view.keyDown(with: event)
        XCTAssertEqual(regions, [CGRect(x: 0, y: 400, width: 230, height: 200)])
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

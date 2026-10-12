import AppKit
import FrameletCore
import XCTest

@testable import Framelet

@MainActor
final class AnnotationInteractionTests: XCTestCase {
    private func model() throws -> RecorderModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "annotation-\(UUID().uuidString)")
        let suite = "AnnotationInteraction-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return RecorderModel(libraryURL: root, defaults: defaults)
    }

    private func board(at rect: CGRect = CGRect(x: -900, y: 400, width: 320, height: 200)) throws
        -> (AnnotationBoard, RecordingEffects, RecorderModel)
    {
        let model = try model()
        let effects = RecordingEffects()
        let board = AnnotationBoard(effects: effects, model: model)
        board.show(over: rect)
        return (board, effects, model)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func stroke(_ board: AnnotationBoard, from start: CGPoint, to end: CGPoint) throws {
        let view = try XCTUnwrap(board.view)
        let window = try XCTUnwrap(board.window)
        view.mouseDown(with: mouse(.leftMouseDown, start, in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, end, in: window))
        view.mouseUp(with: mouse(.leftMouseUp, end, in: window))
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
                pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        return bitmap
    }

    func testBoardIsPointerOnlyAndCaptureMustBeExplicit() async throws {
        let (board, effects, _) = try board()
        defer { board.close() }
        let panel = try XCTUnwrap(board.window)
        let view = try XCTUnwrap(board.view)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isMovable)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(view.needsPanelToBecomeKey)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(panel.ignoresMouseEvents)
        try stroke(board, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 100, y: 60))
        XCTAssertTrue(effects.snapshot(at: 0).marks.isEmpty)
        board.setDrawing(true)
        XCTAssertFalse(panel.ignoresMouseEvents)
        try stroke(board, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 100, y: 60))
        XCTAssertEqual(effects.snapshot(at: 0).marks.count, 1)
        board.setDrawing(false)
        XCTAssertTrue(panel.ignoresMouseEvents)
        try stroke(board, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 200, y: 90))
        XCTAssertEqual(effects.snapshot(at: 0).marks.count, 1)
    }

    func testGlobalPointsUseWindowOriginAndStartedStrokeKeepsItsToolAndColour() async throws {
        let (board, effects, model) = try board()
        defer { board.close() }
        let view = try XCTUnwrap(board.view)
        let panel = try XCTUnwrap(board.window)
        // Event locations remain window-local even when the content view is nested.
        view.frame = CGRect(x: 10, y: 15, width: 300, height: 180)
        board.setDrawing(true)
        model.selectTool(.arrow)
        model.selectColor(3)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 30), in: panel))
        model.selectTool(.highlighter)
        model.selectColor(1)
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 100, y: 60), in: panel))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 120, y: 70), in: panel))
        let mark = try XCTUnwrap(effects.snapshot(at: 0).marks.first)
        XCTAssertEqual(mark.stroke, .arrow)
        XCTAssertEqual(mark.colorIndex, 3)
        XCTAssertEqual(mark.width, AnnotationTool.arrow.strokeWidth)
        XCTAssertEqual(
            mark.points,
            [
                CGPoint(x: -880, y: 430), CGPoint(x: -780, y: 470),
            ])
    }

    func testCompletedMarksAndArrowHeadMatchSharedPainterWithoutVerticalInversion() async throws {
        let (board, effects, model) = try board()
        defer { board.close() }
        board.setDrawing(true)
        model.selectTool(.arrow)
        model.selectColor(3)
        try stroke(board, from: CGPoint(x: 30, y: 35), to: CGPoint(x: 200, y: 75))
        let view = try XCTUnwrap(board.view)
        let actual = try bitmap(view)
        let expected = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: expected))
        NSGraphicsContext.current = graphics
        NSColor(calibratedWhite: 0, alpha: 0.02).setFill()
        view.bounds.fill()
        OverlayPainter.draw(
            effects.snapshot(at: 0), in: graphics.cgContext,
            projection: CaptureProjection(
                frame: board.area, source: view.bounds, bufferSize: view.bounds.size,
                outputSize: view.bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        // Compare the whole overlay including the triangular arrow head and the low-alpha hit
        // surface. The top-left output conversion must still paint at local AppKit y = 35…75.
        XCTAssertEqual(actual.tiffRepresentation, expected.tiffRepresentation)
        let shaft = try XCTUnwrap(actual.colorAt(x: 100, y: 148))
        XCTAssertGreaterThan(shaft.alphaComponent, 0.5)
        let mirrored = try XCTUnwrap(actual.colorAt(x: 100, y: 52))
        XCTAssertLessThan(mirrored.alphaComponent, 0.05)
        board.setDrawing(false)
        let passive = try bitmap(view)
        XCTAssertEqual(
            actual.tiffRepresentation, passive.tiffRepresentation,
            "Completed marks stay visible outside drawing mode")
    }

    func testUndoClearRefreshImmediatelyAndLeaveNoHitSurfaceHoles() async throws {
        let (board, effects, _) = try board()
        defer { board.close() }
        board.setDrawing(true)
        try stroke(board, from: CGPoint(x: 30, y: 40), to: CGPoint(x: 220, y: 40))
        try stroke(board, from: CGPoint(x: 30, y: 80), to: CGPoint(x: 220, y: 80))
        let view = try XCTUnwrap(board.view)
        board.undo()
        XCTAssertEqual(effects.snapshot(at: 0).marks.count, 1)
        let undone = try bitmap(view)
        XCTAssertGreaterThan(try XCTUnwrap(undone.colorAt(x: 100, y: 160)).alphaComponent, 0.5)
        XCTAssertLessThan(try XCTUnwrap(undone.colorAt(x: 100, y: 120)).alphaComponent, 0.05)
        // Clearing during a stroke must prevent the trailing mouse-up from reviving it.
        let window = try XCTUnwrap(board.window)
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20), in: window))
        board.clear()
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 90, y: 90), in: window))
        XCTAssertTrue(effects.snapshot(at: 0).marks.isEmpty)
        let cleared = try bitmap(view)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 319, y: 199)] {
            let alpha = try XCTUnwrap(cleared.colorAt(x: Int(point.x), y: Int(point.y))).alphaComponent
            XCTAssertGreaterThan(alpha, 0.01)
            XCTAssertLessThan(alpha, 0.05)
        }
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testPanelRealContentResizesOnAnnotationAndPhaseChanges() async throws {
        let model = try model()
        let panel = RecordingPanel(model: model)
        defer { panel.close() }
        XCTAssertFalse(panel.window.canBecomeKey)
        XCTAssertFalse(panel.window.canBecomeMain)
        XCTAssertTrue(panel.window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.window.isMovableByWindowBackground)
        model.phase = .recording
        model.annotating = true
        XCTAssertEqual(
            panel.window.contentView?.bounds.size,
            panel.window.contentRect(forFrameRect: panel.window.frame).size)
        XCTAssertEqual(panel.window.frame.height, 132)
        XCTAssertLessThanOrEqual(panel.window.frame.width, 560)
        model.phase = .paused
        XCTAssertEqual(panel.window.frame.height, 132)
        model.phase = .restarting
        XCTAssertEqual(panel.window.frame.height, 76)
        model.phase = .recording
        model.annotating = false
        XCTAssertEqual(panel.window.frame.height, 76)
    }

    func testLayoutFitsSmallAndNegativeOriginScreens() async throws {
        for screen in [
            CGRect(x: -1280, y: 500, width: 1280, height: 720),
            CGRect(x: -320, y: -200, width: 320, height: 240),
            CGRect(x: 0, y: 0, width: 480, height: 300),
        ] {
            for annotating in [false, true] {
                let layout = RecordingPanelLayout(annotating: annotating, availableSize: screen.size)
                let origin = RecordingPanelLayout.clampedOrigin(
                    CGPoint(x: screen.maxX + 50, y: screen.minY - 100), size: layout.size, in: screen)
                XCTAssertTrue(screen.contains(CGRect(origin: origin, size: layout.size)))
                XCTAssertLessThanOrEqual(layout.size.width, screen.width - 16)
                XCTAssertLessThanOrEqual(layout.size.height, screen.height - 16)
                if screen.width < 500 { XCTAssertTrue(layout.compact) }
            }
        }
    }

}

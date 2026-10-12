import AppKit
import FrameletCore

/// A pointer-only preview of the same global-point marks the writer composites into the take.
@MainActor
final class AnnotationBoard {
    private let effects: RecordingEffects
    private weak var model: RecorderModel?
    private(set) var window: AnnotationPanel?
    private(set) var view: StrokeView?
    private(set) var isActive = false

    init(effects: RecordingEffects, model: RecorderModel) {
        self.effects = effects
        self.model = model
    }

    /// The drawable area in global, bottom-left-based AppKit points.
    var area: CGRect { window?.frame ?? .zero }

    func show(over rect: CGRect) {
        close()
        guard rect.width >= 24, rect.height >= 24, !rect.isInfinite, !rect.isNull else { return }
        let window = AnnotationPanel(
            contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        // The drawing surface must remain below the controls when a full-screen area contains them.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenDisallowsTiling,
            .stationary,
        ]
        let view = StrokeView(frame: CGRect(origin: .zero, size: rect.size))
        view.autoresizingMask = [.width, .height]
        view.effects = effects
        view.toolProvider = { [weak model] in model?.annotationTool ?? .pen }
        view.colorProvider = { [weak model] in model?.annotationColor ?? 0 }
        window.contentView = view
        self.window = window
        self.view = view
        isActive = true
        window.orderFrontRegardless()
        refresh()
    }

    func close() {
        view?.setDrawing(false)
        window?.orderOut(nil)
        window?.close()
        window = nil
        view = nil
        isActive = false
    }

    /// Capture is explicit, and never makes the panel or its view a keyboard responder.
    func setDrawing(_ enabled: Bool) {
        if enabled { view?.setMoving(false) }
        view?.setDrawing(enabled)
        window?.ignoresMouseEvents = !(enabled || view?.movingEnabled == true)
        if let view { window?.invalidateCursorRects(for: view) }
    }

    func setMoving(_ enabled: Bool, moveArea: @escaping (CGRect) -> Bool, onFinished: @escaping () -> Void) {
        if enabled { view?.setDrawing(false) }
        view?.moveArea = moveArea
        view?.onMoveFinished = onFinished
        view?.setMoving(enabled)
        window?.ignoresMouseEvents = !(enabled || view?.drawingEnabled == true)
        if let view { window?.invalidateCursorRects(for: view) }
    }

    func move(to rect: CGRect) {
        guard isActive, rect.width >= 24, rect.height >= 24, !rect.isInfinite, !rect.isNull else { return }
        // Do not connect a stroke begun in the old surface to a point in the new surface.
        view?.finishStroke()
        window?.setFrame(rect, display: true)
        refresh()
    }

    func refresh() {
        view?.needsDisplay = true
        view?.displayIfNeeded()
    }

    func undo() {
        view?.finishStroke()
        effects.undo()
        refresh()
    }

    func clear() {
        view?.finishStroke()
        effects.clear()
        refresh()
    }
}

final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum AnnotationTool: String, CaseIterable {
    case pen, highlighter, arrow

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .arrow: return "Arrow"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .pen: return 3
        case .highlighter: return 6
        case .arrow: return 3
        }
    }

    var effectsStroke: RecordingEffects.Stroke {
        switch self {
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .arrow: return .arrow
        }
    }
}

/// Intentionally unflipped: OverlayPainter converts top-left picture points back into a
/// bottom-left CGContext. Giving it a flipped NSView context would invert the preview twice.
final class StrokeView: NSView {
    var effects: RecordingEffects?
    var toolProvider: (() -> AnnotationTool)?
    var colorProvider: (() -> Int)?
    private(set) var drawingEnabled = false
    private(set) var movingEnabled = false
    var moveArea: (CGRect) -> Bool = { _ in false }
    var onMoveFinished: () -> Void = {}
    private var moveStart: CGPoint?
    private var moveFrame: CGRect?
    private var activeMark: UUID?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if movingEnabled {
            addCursorRect(bounds, cursor: .openHand)
        } else if drawingEnabled {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    func setMoving(_ enabled: Bool) {
        if enabled {
            finishStroke()
            drawingEnabled = false
        }
        movingEnabled = enabled
        if !enabled {
            moveStart = nil
            moveFrame = nil
        }
        needsDisplay = true
    }

    func setDrawing(_ enabled: Bool) {
        if !enabled { finishStroke() }
        drawingEnabled = enabled
        needsDisplay = true
    }

    func finishStroke() {
        if let id = activeMark { effects?.finishMark(id: id) }
        activeMark = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if movingEnabled {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            moveStart = globalPoint(of: event)
            moveFrame = window?.frame
            return
        }
        guard drawingEnabled, let effects, let tool = toolProvider?(),
            bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        finishStroke()
        // Tool, colour and width are captured by the mark, not read again while dragging.
        let count = AnnotationColors.markColors.count
        let color = ((colorProvider?() ?? 0) % count + count) % count
        activeMark = effects.beginMark(
            stroke: tool.effectsStroke, at: globalPoint(of: event), colorIndex: color,
            width: tool.strokeWidth)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if movingEnabled {
            guard let moveStart, let moveFrame else { return }
            let point = globalPoint(of: event)
            _ = moveArea(moveFrame.offsetBy(dx: point.x - moveStart.x, dy: point.y - moveStart.y))
            return
        }
        guard drawingEnabled, let effects, let id = activeMark else { return }
        effects.extendMark(id: id, to: globalPoint(of: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if movingEnabled {
            guard moveStart != nil else { return }
            mouseDragged(with: event)
            moveStart = nil
            moveFrame = nil
            onMoveFinished()
            return
        }
        guard drawingEnabled, let effects, let id = activeMark else { return }
        effects.extendMark(id: id, to: globalPoint(of: event))
        finishStroke()
    }

    private func globalPoint(of event: NSEvent) -> CGPoint {
        // Event locations are already window-local, not view-local. This also handles a view
        // nested at a nonzero origin, and screens left of or above the primary display.
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func rightMouseDown(with event: NSEvent) {
        if movingEnabled { onMoveFinished() }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A truly clear window has click-through holes on macOS, even with ignoresMouseEvents
        // disabled. Keep a barely visible, continuous hit surface, including after undo/clear.
        NSColor(calibratedWhite: 0, alpha: 0.02).setFill()
        bounds.fill()
        if movingEnabled {
            NSColor.systemMint.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            border.stroke()
        }
        guard let effects, let window, let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        let projection = CaptureProjection(
            frame: frame, source: CGRect(origin: .zero, size: bounds.size),
            bufferSize: bounds.size, outputSize: bounds.size)
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        OverlayPainter.draw(
            effects.snapshot(at: ProcessInfo.processInfo.systemUptime), in: context,
            projection: projection)
        context.restoreGState()
    }
}

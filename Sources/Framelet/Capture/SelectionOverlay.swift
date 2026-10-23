import AppKit
import FrameletCore

final class SelectionPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        title = "Choose Recording Area"
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }
    // Even a nonactivating panel can steal key focus and dismiss another app's popover.
    // Keyboard confirmation is handled by temporary hot keys instead.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onWindowSelect: ((WindowCandidate) -> Void)?
    var onCancel: (() -> Void)?
    var screenOrigin: CGPoint = .zero
    var candidates: [WindowCandidate] = []
    var keyboardHint = "Return to confirm, ⎋ to cancel"
    var onKeyboardConfirm: (() -> Void)?
    private var hovered: WindowCandidate?
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var dragging = false
    private var mouseTracking: NSTrackingArea?
    private var committed = false
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(tracking)
        mouseTracking = tracking
    }
    func updateHover(globalPoint: CGPoint) {
        guard anchor == nil else { return }
        hovered = WindowSelection.hit(at: globalPoint, candidates: candidates)
        selection = hovered.map {
            $0.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).intersection(bounds)
        }
        if selection?.isNull == true {
            selection = nil
            hovered = nil
        }
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) { updateHover(globalPoint: NSEvent.mouseLocation) }
    override func mouseEntered(with event: NSEvent) { updateHover(globalPoint: NSEvent.mouseLocation) }
    override func mouseExited(with event: NSEvent) {
        if anchor == nil {
            hovered = nil
            selection = nil
            needsDisplay = true
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            if let onKeyboardConfirm { onKeyboardConfirm() } else { confirmWindow() }
        }
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func mouseDown(with event: NSEvent) {
        guard !committed else { return }
        anchor = nil
        let location = point(event)
        updateHover(globalPoint: CGPoint(x: location.x + screenOrigin.x, y: location.y + screenOrigin.y))
        anchor = point(event)
        dragging = false
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let current = point(event)
        guard dragging || hypot(current.x - anchor.x, current.y - anchor.y) > 5 else { return }
        dragging = true
        hovered = nil
        selection = CGRect(
            x: min(anchor.x, current.x), y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !committed, anchor != nil else { return }
        mouseDragged(with: event)
        if !dragging, hovered != nil {
            confirmWindow()
            return
        }
        guard dragging else {
            anchor = nil
            return
        }
        guard let selection, selection.width >= 24, selection.height >= 24 else {
            anchor = nil
            selection = nil
            needsDisplay = true
            return
        }
        committed = true
        anchor = nil
        onSelect?(selection.integral.intersection(bounds))
    }
    func confirmWindow() {
        guard !committed, let hovered else { return }
        committed = true
        anchor = nil
        // A dropdown cannot be captured as a window, so its frame is recorded as the area it covers.
        if hovered.isMenu {
            onSelect?(hovered.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).intersection(bounds))
        } else {
            onWindowSelect?(hovered)
        }
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        // A fully transparent hole can pass clicks to the underlying app on macOS.
        // Keep a barely visible hit surface over the entire selected window, including its title bar.
        NSColor.black.withAlphaComponent(0.02).setFill()
        bounds.fill(using: .copy)
        let shade = NSBezierPath(rect: bounds)
        if let selection { shade.append(NSBezierPath(rect: selection)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.40).setFill()
        shade.fill()
        if let selection {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1.5
            outline.stroke()
            let size =
                hovered.map {
                    String($0.title.prefix(65))
                        + ($0.isMenu
                            ? ". Press \(RecorderShortcuts.captureLabel) to record this area"
                            : ". Click to record this window")
                }
                ?? "\(Int(selection.width)) × \(Int(selection.height))"
            drawLabel(size, at: CGPoint(x: selection.midX, y: max(20, selection.minY - 34)), fontSize: 12)
        }
        drawLabel(
            "Click a window or drag an area. \(keyboardHint)",
            at: CGPoint(x: bounds.midX, y: bounds.height - 96), fontSize: 15)
    }

    private func drawLabel(_ text: String, at point: CGPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(
            x: min(max(12, point.x - size.width / 2 - 16), bounds.width - size.width - 44),
            y: point.y, width: size.width + 32, height: size.height + 18)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 9), withAttributes: attributes)
    }
}

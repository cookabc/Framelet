import AppKit
import Combine
import FrameletCore
import SwiftUI

@MainActor
final class RecordingPanel {
    private(set) var window: NSPanel
    private(set) var border: NSWindow?
    private weak var model: RecorderModel?
    private(set) var regionRect: CGRect?
    private var regionScreen: NSScreen?
    private var observations: Set<AnyCancellable> = []
    private let presentation = RecordingPanelPresentation()
    private var hostingView: NSHostingView<RecordingHUD>?

    init(model: RecorderModel) {
        self.model = model
        window = RecordingControlsPanel(
            contentRect: CGRect(origin: .zero, size: RecordingPanelLayout.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .screenSaver
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.title = "Recording Controls"
        window.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenDisallowsTiling,
        ]
        resize(annotating: model.isAnnotating)
        // @Published emits before assignment. Resize from the emitted values but keep the same
        // hosting view subscribed: replacing it here leaves a paused take showing Starting.
        model.$annotating.combineLatest(model.$phase)
            .map { $0 && ($1 == .recording || $1 == .paused) }
            .removeDuplicates()
            .sink { [weak self] annotating in self?.resize(annotating: annotating) }
            .store(in: &observations)
    }

    func show(near region: CaptureRegion) {
        border?.close()
        border = nil
        regionRect = region.rect
        regionScreen = region.screen
        resize(annotating: model?.isAnnotating == true)
        let screen = region.screen.visibleFrame
        let size = window.frame.size
        let preferredY = region.rect.minY - size.height - 12
        let origin = CGPoint(
            x: region.rect.midX - size.width / 2,
            y: preferredY >= screen.minY + 8 ? preferredY : region.rect.maxY + 12)
        window.setFrameOrigin(RecordingPanelLayout.clampedOrigin(origin, size: size, in: screen))
        window.orderFrontRegardless()

        guard region.windowID == nil else { return }
        let border = NSWindow(
            contentRect: region.rect.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered,
            defer: false)
        border.isReleasedWhenClosed = false
        border.backgroundColor = .clear
        border.isOpaque = false
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenDisallowsTiling,
            .stationary,
        ]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemMint.cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 3
        border.contentView = view
        border.orderFrontRegardless()
        self.border = border
    }

    private func resize(annotating: Bool) {
        guard let model else { return }
        let screen = window.screen ?? regionScreen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let layout = RecordingPanelLayout(annotating: annotating, availableSize: visibleFrame.size)
        let oldFrame = window.frame
        window.setContentSize(layout.size)
        let origin = CGPoint(x: oldFrame.minX, y: oldFrame.maxY - layout.size.height)
        window.setFrameOrigin(
            RecordingPanelLayout.clampedOrigin(origin, size: layout.size, in: visibleFrame))
        presentation.layout = layout
        if hostingView == nil {
            let view = NSHostingView(
                rootView: RecordingHUD(
                    model: model, live: model.live, presentation: presentation,
                    areaProvider: { [weak self] in self?.regionRect },
                    moveArea: { [weak self] in self?.moveArea(to: $0) ?? false }))
            view.autoresizingMask = [.width, .height]
            hostingView = view
            window.contentView = view
        }
    }

    /// Only the dedicated Move area handle enters this path. Moving the controls window has
    /// no observer and cannot change capture geometry.
    @discardableResult
    func moveArea(to proposed: CGRect) -> Bool {
        guard let model, model.canMoveRegion, let original = regionRect, let screen = regionScreen else {
            return false
        }
        let frame = screen.frame
        let rect = CGRect(
            origin: CGPoint(
                x: min(max(proposed.minX, frame.minX), frame.maxX - original.width),
                y: min(max(proposed.minY, frame.minY), frame.maxY - original.height)),
            size: original.size)
        guard
            let aligned = CaptureGeometry.alignedMovement(
                rect, screen: frame, scale: screen.backingScaleFactor),
            model.moveRegion(to: aligned)
        else { return false }
        regionRect = aligned
        border?.setFrame(aligned.insetBy(dx: -2, dy: -2), display: true)
        return true
    }

    func close() {
        regionRect = nil
        regionScreen = nil
        window.orderOut(nil)
        border?.close()
        border = nil
    }
}

final class RecordingControlsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Pure sizing policy also exercised without a screen-capture session.
struct RecordingPanelLayout {
    static let defaultSize = CGSize(width: 520, height: 76)
    let size: CGSize
    let annotating: Bool
    var compact: Bool { size.width < 500 }
    var compactAnnotations: Bool { size.width < 560 }
    var narrow: Bool { size.width < 340 }

    init(annotating: Bool, availableSize: CGSize) {
        self.annotating = annotating
        size = CGSize(
            width: min(annotating ? 560 : Self.defaultSize.width, max(1, availableSize.width - 16)),
            height: min(annotating ? 132 : Self.defaultSize.height, max(1, availableSize.height - 16)))
    }

    static func clampedOrigin(_ origin: CGPoint, size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8),
            y: min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8))
    }
}

/// AppKit owns this gesture so it cannot fall through to NSPanel's background window dragging.
/// A fixed start rectangle and global pointer delta avoid drift when the region hits a screen edge.
final class RegionMoveHandle: NSView {
    var canMove: () -> Bool = { false }
    var areaProvider: () -> CGRect? = { nil }
    var moveArea: (CGRect) -> Bool = { _ in false }
    var onClick: () -> Void = {}
    private var startPoint: CGPoint?
    private var startRect: CGRect?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if canMove() { addCursorRect(bounds, cursor: .openHand) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard canMove() else { return false }
        onClick()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = nil
        startRect = nil
        didDrag = false
        guard canMove(), let rect = areaProvider() else { return }
        startPoint = globalPoint(event)
        startRect = rect
    }

    override func mouseDragged(with event: NSEvent) {
        guard canMove(), let startPoint, let startRect else { return }
        let point = globalPoint(event)
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        guard didDrag || hypot(dx, dy) >= 3 else { return }
        didDrag = true
        _ = moveArea(startRect.offsetBy(dx: dx, dy: dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        mouseDragged(with: event)
        if canMove(), !didDrag { onClick() }
        startPoint = nil
        startRect = nil
        didDrag = false
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}

private struct MoveAreaControl: NSViewRepresentable {
    var canMove: () -> Bool
    var areaProvider: () -> CGRect?
    var moveArea: (CGRect) -> Bool
    var onClick: () -> Void

    func makeNSView(context: Context) -> RegionMoveHandle { RegionMoveHandle() }
    func updateNSView(_ view: RegionMoveHandle, context: Context) {
        view.canMove = canMove
        view.areaProvider = areaProvider
        view.moveArea = moveArea
        view.onClick = onClick
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Move area")
        view.setAccessibilityHelp("Click, then drag inside the recording area, or drag this handle directly")
        view.window?.invalidateCursorRects(for: view)
    }
}

private final class RecordingPanelPresentation: ObservableObject {
    @Published var layout = RecordingPanelLayout(
        annotating: false, availableSize: CGSize(width: 1024, height: 768))
}

private struct RecordingHUD: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var live: RecorderLiveState
    @ObservedObject var presentation: RecordingPanelPresentation
    private var layout: RecordingPanelLayout { presentation.layout }
    var areaProvider: () -> CGRect?
    var moveArea: (CGRect) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            controls.frame(height: min(76, layout.size.height))
            if layout.annotating {
                Divider().overlay(.white.opacity(0.12)).padding(.horizontal, 12)
                annotationBar.frame(maxHeight: .infinity)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .foregroundStyle(.white)
        .background(
            Color(red: 0.09, green: 0.14, blue: 0.15), in: RoundedRectangle(cornerRadius: 15))
    }

    private var controls: some View {
        HStack(spacing: layout.compact ? 8 : 12) {
            if !layout.narrow {
                Circle().fill(model.phase == .recording ? Color.red : Color.mint)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.75).controlID(ControlID.hudTime)
                if !layout.compact {
                    Text(subtitle).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.canControlRecording {
                if model.canMoveRegion { moveHandle }
                if model.canAnnotate { annotateButton }
                if layout.compact {
                    Menu {
                        Button(model.phase == .paused ? "Resume recording" : "Pause recording") {
                            model.togglePause()
                        }.disabled(model.pauseIsChanging)
                        Button("Record again") { model.restartRecording() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 32, height: 36).accessibilityLabel("Recording actions")
                } else {
                    Button {
                        model.togglePause()
                    } label: {
                        Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(RecorderButtonStyle(tone: .dark, height: 36))
                        .disabled(model.pauseIsChanging)
                        .help(
                            (model.phase == .paused ? "Resume recording " : "Pause recording ")
                                + RecorderShortcuts.pauseLabel
                        )
                        .accessibilityLabel(model.phase == .paused ? "Resume recording" : "Pause recording")
                        .controlID(ControlID.hudPause)
                    Button {
                        model.restartRecording()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }.buttonStyle(RecorderButtonStyle(tone: .dark, height: 36))
                        .help("Save this take, then start a new one").accessibilityLabel("Record again")
                }
                Button {
                    model.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                }.buttonStyle(RecorderButtonStyle(tone: .dark, height: 36))
                    .accessibilityLabel("Stop recording").controlID(ControlID.hudStop)
            } else if model.isCountingDown {
                Button {
                    model.cancelSelection()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(RecorderButtonStyle(tone: .dark, height: 36))
                    .accessibilityLabel("Cancel recording")
            } else {
                ProgressView().controlSize(.small).colorScheme(.dark)
            }
        }.padding(.horizontal, layout.compact ? 12 : 16)
    }

    private var moveHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 13))
            .frame(width: 32, height: 36)
            .background(
                model.isMovingRegion ? Color.mint.opacity(0.35) : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .opacity(model.canMoveRegion ? 1 : 0.4)
            .overlay {
                MoveAreaControl(
                    canMove: { model.canMoveRegion }, areaProvider: areaProvider, moveArea: moveArea,
                    onClick: { model.toggleMovingRegion() })
            }
            .help("Click, then drag inside the recording area; or drag this handle directly")
    }

    private var annotateButton: some View {
        Button {
            model.toggleAnnotating()
        } label: {
            Image(systemName: model.isAnnotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }.buttonStyle(RecorderButtonStyle(tone: model.isAnnotating ? .accent : .dark, height: 36))
            .help(model.isAnnotating ? "Stop drawing on the recording" : "Draw on the recording")
            .disabled(!model.canAnnotate)
            .accessibilityLabel(model.isAnnotating ? "Stop annotating" : "Annotate")
    }

    private var annotationBar: some View {
        HStack(spacing: layout.compact ? 12 : 8) {
            if layout.compact {
                Menu {
                    ForEach(AnnotationTool.allCases, id: \.self) { tool in
                        Button {
                            model.selectTool(tool)
                        } label: {
                            Label(tool.label, systemImage: tool.symbol)
                        }
                    }
                } label: {
                    Image(systemName: model.annotationTool.symbol)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 36, height: 36).accessibilityLabel("Annotation tool")
                Menu {
                    ForEach(0..<AnnotationColors.markColors.count, id: \.self) { index in
                        Button {
                            model.selectColor(index)
                        } label: {
                            Label(
                                colorName(index),
                                systemImage: model.annotationColor == index ? "checkmark.circle" : "circle")
                        }
                    }
                } label: {
                    colorSwatch(model.annotationColor)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 36, height: 36).accessibilityLabel("Annotation colour")
            } else {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        model.selectTool(tool)
                    } label: {
                        Image(systemName: tool.symbol)
                    }.buttonStyle(
                        RecorderButtonStyle(tone: model.annotationTool == tool ? .accent : .dark, height: 36)
                    )
                    .help(tool.label).accessibilityLabel(tool.label)
                }
                Divider().frame(height: 18)
                ForEach(0..<AnnotationColors.markColors.count, id: \.self) { index in
                    Button {
                        model.selectColor(index)
                    } label: {
                        colorSwatch(index)
                    }
                    .buttonStyle(.plain).frame(width: 24, height: 36)
                    .help(colorName(index)).accessibilityLabel(colorName(index))
                }
                Divider().frame(height: 18)
            }
            Button {
                model.undoAnnotation()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }.buttonStyle(RecorderButtonStyle(tone: .dark, height: 36))
                .help("Undo the last mark").accessibilityLabel("Undo annotation")
            Button {
                model.clearAnnotations()
            } label: {
                Image(systemName: "eraser")
            }.buttonStyle(RecorderButtonStyle(tone: .dark, height: 36))
                .help("Clear all marks").accessibilityLabel("Clear annotations")
        }
        .padding(.horizontal, 12)
        .disabled(!model.canAnnotate)
    }

    private func colorSwatch(_ index: Int) -> some View {
        let colors = AnnotationColors.markColors
        let selected = (index % colors.count + colors.count) % colors.count
        return Circle().fill(Color(cgColor: colors[selected])).frame(width: 13, height: 13)
            .overlay(Circle().stroke(.white, lineWidth: model.annotationColor == selected ? 2 : 0))
    }

    private func colorName(_ index: Int) -> String {
        ["Red", "Yellow", "Green", "Blue", "Purple"][index]
    }

    private var subtitle: String {
        if model.isMovingRegion { return "Drag area, right-click cancels" }
        if model.isWindowRecording { return "Follows window; drag-select an area to annotate" }
        if model.isAnnotating { return "Draw area, pencil exits" }
        if case .countdown = model.phase { return "Arrange what you want to capture" }
        return model.recordingTitle
    }

    private var title: String {
        if model.pauseIsChanging { return model.phase == .paused ? "Resuming…" : "Pausing…" }
        if model.isMovingRegion { return "Move area" }
        switch model.phase {
        case .countdown(let value): return "Recording in \(value)"
        case .starting: return "Starting…"
        case .paused: return "Paused  \(live.formattedElapsed)"
        case .stopping: return "Saving…"
        case .restarting: return "Saving, then restarting…"
        default: return live.formattedElapsed
        }
    }
}

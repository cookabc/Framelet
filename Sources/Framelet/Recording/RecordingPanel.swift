import AppKit
import SwiftUI

@MainActor
final class RecordingPanel {
    private let window: NSPanel
    private var border: NSWindow?

    init(model: RecorderModel) {
        window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 76),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.title = "Recording Controls"
        window.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenDisallowsTiling,
        ]
        window.contentView = NSHostingView(rootView: RecordingHUD(model: model))
    }

    func show(near region: CaptureRegion) {
        let screen = region.screen.visibleFrame
        let x = min(max(region.rect.midX - 230, screen.minX + 8), screen.maxX - 468)
        let preferredY = region.rect.minY - 90
        let y = preferredY >= screen.minY ? preferredY : min(region.rect.maxY + 12, screen.maxY - 88)
        window.setFrameOrigin(CGPoint(x: x, y: max(screen.minY + 8, y)))
        window.orderFrontRegardless()

        // Independent-window recording follows the window, so a fixed desktop border would be misleading.
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

    func close() {
        window.orderOut(nil)
        border?.close()
        border = nil
    }
}

private struct RecordingHUD: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.phase == .recording ? Color.red : Color.mint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(subtitle).lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if model.canControlRecording {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill")
                }.buttonStyle(RecorderButtonStyle(tone: .dark))
                    .help(
                        (model.phase == .paused ? "Resume recording " : "Pause recording ")
                            + RecorderShortcuts.pauseLabel
                    )
                    .accessibilityLabel(model.phase == .paused ? "Resume recording" : "Pause recording")
                Button {
                    model.restartRecording()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(RecorderButtonStyle(tone: .dark)).help("Save this take, then start a new one")
                .accessibilityLabel("Record again")
                Button {
                    model.stopRecording()
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 14))
                }.buttonStyle(RecorderButtonStyle(tone: .dark))
                    .accessibilityLabel("Stop recording")
            } else if model.isCountingDown {
                Button {
                    model.cancelSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(RecorderButtonStyle(tone: .dark)).accessibilityLabel("Cancel recording")
            } else {
                ProgressView().controlSize(.small).colorScheme(.dark)
            }
        }
        .padding(.horizontal, 16).frame(width: 460, height: 76)
        .foregroundStyle(.white).background(
            Color(red: 0.09, green: 0.14, blue: 0.15), in: RoundedRectangle(cornerRadius: 15))
    }
    private var subtitle: String {
        if case .countdown = model.phase { return "Keep your menu open, or arrange what you want to capture" }
        return model.recordingTitle
    }

    private var title: String {
        switch model.phase {
        case .countdown(let value): return "Recording in \(value)"
        case .starting: return "Starting…"
        case .pausing: return "Pausing…"
        case .paused: return "Paused  \(model.formattedElapsed)"
        case .stopping: return "Saving…"
        case .restarting: return "Saving, then restarting…"
        default: return model.formattedElapsed
        }
    }
}

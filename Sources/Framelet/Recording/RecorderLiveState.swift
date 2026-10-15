import Combine

/// The values that change many times per second while a take or an export is running.
///
/// They live apart from `RecorderModel` on purpose: `@Published` invalidates every view that
/// observes the object it belongs to, and `MainView` observes the model at the root, so one tick
/// of the 10 Hz playback clock used to recompute the whole 880 × 650 window. Views that display
/// only these numbers observe this object instead, and a tick then repaints just the readout.
@MainActor
final class RecorderLiveState: ObservableObject {
    @Published var elapsed = 0.0
    @Published var playbackTime = 0.0
    @Published var exportProgress = 0.0

    var formattedElapsed: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// The ticker runs at 5 Hz but both readouts show whole seconds, so the other four writes
    /// repaint pixels that cannot have changed.
    func tickElapsed(_ value: Double) {
        let published = Int(value) != Int(elapsed)
        PerfSignpost.liveWrite("elapsed", published: published) {
            if published { elapsed = value }
        }
    }

    /// The GIF encoder reports once per frame; a 60 s take would otherwise repaint the progress row
    /// about 1800 times. The row only renders a whole percent.
    func setExportProgress(_ value: Double) {
        let published = Int(value * 100) != Int(exportProgress * 100)
        PerfSignpost.liveWrite("exportProgress", published: published) {
            if published { exportProgress = value }
        }
    }
}

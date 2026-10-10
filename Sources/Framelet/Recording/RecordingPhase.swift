enum RecordingPhase: Equatable {
    case idle, selecting
    case countdown(Int)
    case starting, recording, pausing, paused, stopping, restarting

    /// Status for the main window, which stays visible through the transitions the floating
    /// control bar covers with its own wording.
    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .selecting: return "Choosing area"
        case .countdown: return "Getting ready"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .pausing: return "Pausing…"
        case .paused: return "Paused"
        case .stopping: return "Saving…"
        case .restarting: return "Saving, then restarting…"
        }
    }
}

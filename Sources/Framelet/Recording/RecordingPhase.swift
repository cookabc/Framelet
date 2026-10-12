enum RecordingPhase: Equatable {
    case idle, selecting
    case countdown(Int)
    case starting, recording, paused, stopping, restarting

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .selecting: return "Choosing area"
        case .countdown: return "Getting ready"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving…"
        case .restarting: return "Saving, then restarting…"
        }
    }
}

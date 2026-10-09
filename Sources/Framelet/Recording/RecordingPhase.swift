enum RecordingPhase: Equatable {
    case idle, selecting
    case countdown(Int)
    case starting, recording, pausing, paused, stopping, restarting
}

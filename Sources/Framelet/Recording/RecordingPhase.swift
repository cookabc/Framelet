enum RecordingPhase: Equatable {
    case idle, selecting
    case countdown(Int)
    case starting, recording, pausing, paused, stopping, restarting

    /// Status for the main window, which stays visible through the transitions the floating
    /// control bar covers with its own wording.
    var statusText: String {
        switch self {
        case .idle: return "就绪"
        case .selecting: return "选择范围"
        case .countdown: return "准备中"
        case .starting: return "正在启动…"
        case .recording: return "录制中"
        case .pausing: return "正在暂停…"
        case .paused: return "已暂停"
        case .stopping: return "正在保存…"
        case .restarting: return "保存后重新开始…"
        }
    }
}

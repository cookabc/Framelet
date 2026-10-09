/// Uses monotonic timestamps so time spent paused and wall-clock changes are excluded.
public struct RecordingClock {
    private var accumulated: Double = 0
    private var started: Double?
    public init() {}
    public mutating func resume(at time: Double) { if started == nil { started = time } }
    public mutating func pause(at time: Double) {
        accumulated = elapsed(at: time)
        started = nil
    }
    public func elapsed(at time: Double) -> Double {
        accumulated + (started.map { max(0, time - $0) } ?? 0)
    }
    public mutating func reset() {
        accumulated = 0
        started = nil
    }
}

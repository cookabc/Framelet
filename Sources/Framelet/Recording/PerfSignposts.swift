import os

/// Signposts for the writes that decide whether a view repaints.
///
/// The in-process harness produces the numbers; these events put the same decisions on a timeline
/// of the *running* app, where the point is to see that a 5 Hz ticker yields one repaint per
/// second and a per-frame export callback yields one per percent. Debug-only, like `SensorHub` in
/// 037-vitals.
///
///     log stream --level debug --style compact --predicate 'subsystem == "studio.framelet.mac"'
enum PerfSignpost {
    #if DEBUG
        private static let log = OSLog(subsystem: "studio.framelet.mac", category: "perf")
        private static let logger = Logger(subsystem: "studio.framelet.mac", category: "perf")
    #endif

    /// Marks one live-value write. `apply` performs the assignment, so an interval in Instruments
    /// spans the `@Published` fan-out; `published: false` records a write the throttle dropped.
    static func liveWrite(_ field: String, published: Bool, _ apply: () -> Void) {
        #if DEBUG
            let id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: "live-write", signpostID: id)
            apply()
            os_signpost(.end, log: log, name: "live-write", signpostID: id)
            logger.info(
                "live_write field=\(field, privacy: .public) published=\(published, privacy: .public)")
        #else
            apply()
        #endif
    }

    /// One forced repaint measured by the harness: body+layout and full-window paint in microseconds.
    static func repaintSample(layoutUS: Int, paintUS: Int, clips: Int) {
        #if DEBUG
            os_signpost(.event, log: log, name: "warm-repaint")
            logger.info("warm_repaint clips=\(clips) layout_us=\(layoutUS) paint_us=\(paintUS)")
        #endif
    }
}

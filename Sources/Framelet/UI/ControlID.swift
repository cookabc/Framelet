import SwiftUI

/// Identifiers for the controls a UI test drives or asserts on.
///
/// The strings are a test contract: changing one breaks the test on purpose, so that a renamed or
/// removed control cannot silently stop being covered.
enum ControlID {
    static let newRecording = "framelet.newRecording"
    static let openLibrary = "framelet.openLibrary"
    static let chooseArea = "framelet.chooseArea"
    static let showFile = "framelet.showFile"
    static let playToggle = "framelet.playToggle"
    static let playbackSlider = "framelet.playbackSlider"
    static let elapsed = "framelet.elapsed"
    static let pauseRecording = "framelet.pauseRecording"
    static let recordAgain = "framelet.recordAgain"
    static let stopRecording = "framelet.stopRecording"
    static let exportFormat = "framelet.exportFormat"
    static let exportButton = "framelet.exportButton"
    static let exportStart = "framelet.exportStart"
    static let exportDuration = "framelet.exportDuration"
    static let resetRange = "framelet.resetRange"
    static let exportProgress = "framelet.exportProgress"
    static let cancelExport = "framelet.cancelExport"
    static let hudTime = "framelet.hud.time"
    static let hudStop = "framelet.hud.stop"
    static let hudPause = "framelet.hud.pause"
}

extension View {
    func controlID(_ id: String) -> some View { accessibilityIdentifier(id) }
}

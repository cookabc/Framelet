import AppKit
import FrameletCore
import XCTest

@testable import Framelet

/// Opt-in diagnostic: keep the named application's popup open on an authorised desktop.
@MainActor
final class LivePanelCaptureTests: XCTestCase {
    func testDragThroughRealRecorder() async throws {
        guard let owner = ProcessInfo.processInfo.environment["FRAMELET_LIVE_PANEL_OWNER"] else {
            throw XCTSkip("Set FRAMELET_LIVE_PANEL_OWNER to exercise a real open popup")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let descriptions =
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let item = try XCTUnwrap(
            descriptions.first {
                ($0[kCGWindowOwnerName as String] as? String)?.lowercased() == owner.lowercased()
                    && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
            })
        let bounds = try XCTUnwrap(item[kCGWindowBounds as String] as? [String: Any])
        let quartz = try XCTUnwrap(CGRect(dictionaryRepresentation: bounds as CFDictionary))
        let frame = WindowSelection.appKitRect(
            fromQuartz: quartz, primaryTop: NSScreen.screens.first!.frame.maxY)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "framelet-live-\(UUID().uuidString)", isDirectory: true)
        let suite = "FrameletLive-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecorderModel(libraryURL: root, defaults: defaults)
        model.countdownSeconds = 1
        model.beginSelection()
        defer {
            if model.phase == .selecting || model.isCountingDown { model.cancelSelection() }
            if model.hasActiveRecording { model.stopRecording() }
        }
        var overlay: NSWindow?
        for _ in 0..<100 {
            overlay = NSApp.windows.first {
                $0.isVisible && $0.contentView is SelectionView && $0.frame.contains(frame.origin)
            }
            if overlay != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let panel = try XCTUnwrap(overlay, model.errorMessage ?? "No selector")
        let view = try XCTUnwrap(panel.contentView as? SelectionView)
        let chosen = CGRect(x: frame.minX + 5, y: frame.maxY - 320, width: 430, height: 220)
        let local = chosen.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, local.origin))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: local.maxX, y: local.maxY)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: local.maxX, y: local.maxY)))
        for _ in 0..<100 {
            if model.phase == .recording || model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.phase, .recording, model.errorMessage ?? "Recording never started")
        guard model.phase == .recording else { return }
        try await Task.sleep(for: .seconds(1))
        model.togglePause()
        for _ in 0..<100 {
            if model.phase == .paused || model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.phase, .paused, model.errorMessage ?? "Pause never completed")
        guard model.phase == .paused else { return }
        try await Task.sleep(for: .milliseconds(300))
        model.togglePause()
        for _ in 0..<100 {
            if model.phase == .recording || model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.phase, .recording, model.errorMessage ?? "Resume never completed")
        guard model.phase == .recording else { return }
        try await Task.sleep(for: .seconds(1))
        model.stopRecording()
        for _ in 0..<100 {
            if model.phase == .idle { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.clips.count, 1)
        print("LIVE_PANEL_CAPTURE", model.clips.first?.url.path ?? root.path, "selected", chosen)
    }
}

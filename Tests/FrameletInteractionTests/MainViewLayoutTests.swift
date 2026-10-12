import AppKit
import SwiftUI
import XCTest

@testable import Framelet

@MainActor
final class MainViewLayoutTests: XCTestCase {
    func testMinimumWindowRendersBothExportFormatsWithinItsBounds() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "main-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FrameletLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecorderModel(libraryURL: root, defaults: defaults)
        model.selected = RecordedClip(
            url: root.appendingPathComponent("preview.mp4"), date: Date(timeIntervalSince1970: 0))
        model.duration = 42
        model.resolution = "1920 × 1080"
        for format in [ClipExportFormat.video, .gif] {
            model.setExportFormat(format)
            let panel = NSPanel(
                contentRect: CGRect(x: 100, y: 100, width: 880, height: 650),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: MainView(model: model))
            view.frame = CGRect(x: 0, y: 0, width: 880, height: 650)
            panel.contentView = view
            defer { panel.close() }
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.bounds.size, CGSize(width: 880, height: 650))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            if let directory = ProcessInfo.processInfo.environment["FRAMELET_UI_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("main-\(format.rawValue).png"))
            }
        }
    }
}

import AVFoundation
import AppKit
import FrameletCore
import XCTest

@testable import Framelet

@MainActor
final class VideoPreviewInteractionTests: XCTestCase {
    func testActualPreviewViewKeepsVideoAtDisplayPixelSizeAndCanFit() throws {
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 600, height: 320),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let container = VideoPreviewContainer(frame: CGRect(x: 0, y: 0, width: 600, height: 320))
        panel.contentView = container
        let player = AVPlayer()
        container.configure(player: player, pixelSize: CGSize(width: 300, height: 160), sizing: .actualSize)
        container.layoutSubtreeIfNeeded()
        let scale = panel.backingScaleFactor
        XCTAssertTrue(container.playerView.player === player)
        XCTAssertEqual(container.playerView.frame.width * scale, 300, accuracy: 0.5)
        XCTAssertEqual(container.playerView.frame.height * scale, 160, accuracy: 0.5)
        container.configure(player: player, pixelSize: CGSize(width: 300, height: 160), sizing: .fitWindow)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.playerView.frame.size, CGSize(width: 600, height: 320))
        XCTAssertTrue(container.playerView.player === player, "Changing preview size must not reset playback")
    }

    func testLoadingActualClipSetsPixelMetadataWithoutChangingExportRange() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "preview-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await makeRecoverySegment(in: root)
        let suite = "FrameletPreviewMetadata-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecorderModel(libraryURL: root, defaults: defaults)
        for _ in 0..<200 {
            if model.videoPixelSize != .zero { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.previewSizing, .actualSize)
        XCTAssertEqual(model.videoPixelSize, CGSize(width: 160, height: 90))
        let start = model.exportStart
        let duration = model.exportDuration
        model.previewSizing = .fitWindow
        XCTAssertEqual(model.exportStart, start)
        XCTAssertEqual(model.exportDuration, duration)
        XCTAssertEqual(model.selected?.url.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }
}

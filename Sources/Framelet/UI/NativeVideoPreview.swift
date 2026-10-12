import AVKit
import FrameletCore
import SwiftUI

struct NativeVideoPreview: NSViewRepresentable {
    let player: AVPlayer?
    let pixelSize: CGSize
    let sizing: VideoPreviewSizing

    func makeNSView(context: Context) -> VideoPreviewContainer {
        let view = VideoPreviewContainer()
        view.configure(player: player, pixelSize: pixelSize, sizing: sizing)
        return view
    }

    func updateNSView(_ view: VideoPreviewContainer, context: Context) {
        view.configure(player: player, pixelSize: pixelSize, sizing: sizing)
    }

    static func dismantleNSView(_ view: VideoPreviewContainer, coordinator: ()) {
        view.playerView.player = nil
    }
}

final class VideoPreviewContainer: NSView {
    let playerView = AVPlayerView()
    private var pixelSize = CGSize.zero
    private var sizing: VideoPreviewSizing = .actualSize

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        playerView.controlsStyle = .none
        playerView.allowsVideoFrameAnalysis = false
        playerView.videoGravity = .resizeAspect
        addSubview(playerView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(player: AVPlayer?, pixelSize: CGSize, sizing: VideoPreviewSizing) {
        if playerView.player !== player { playerView.player = player }
        self.pixelSize = pixelSize
        self.sizing = sizing
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let rect = VideoPreviewGeometry.frame(
            pixelSize: pixelSize, available: bounds.size,
            backingScale: scale, sizing: sizing)
        playerView.frame = rect.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

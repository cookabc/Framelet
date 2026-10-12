import CoreGraphics

public enum VideoPreviewSizing: String, CaseIterable {
    case actualSize, fitWindow
}

public enum VideoPreviewGeometry {
    /// Original size means one video pixel per display pixel, not one video pixel per AppKit
    /// point. Large clips can shrink to fit, but small clips are never enlarged in this mode.
    public static func frame(
        pixelSize: CGSize, available: CGSize, backingScale: CGFloat,
        sizing: VideoPreviewSizing
    ) -> CGRect {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
            pixelSize.width > 0, pixelSize.height > 0,
            available.width.isFinite, available.height.isFinite,
            available.width > 0, available.height > 0,
            backingScale.isFinite, backingScale > 0
        else { return .zero }
        let native = CGSize(width: pixelSize.width / backingScale, height: pixelSize.height / backingScale)
        let fit = min(available.width / native.width, available.height / native.height)
        let factor = sizing == .actualSize ? min(1, fit) : fit
        let width = floor(native.width * factor * backingScale) / backingScale
        let height = floor(native.height * factor * backingScale) / backingScale
        let x = floor((available.width - width) / 2 * backingScale) / backingScale
        let y = floor((available.height - height) / 2 * backingScale) / backingScale
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

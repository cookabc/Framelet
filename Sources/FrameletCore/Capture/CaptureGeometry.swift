import CoreGraphics
import Foundation

public enum CaptureGeometry {
    /// AppKit uses a bottom-left origin; ScreenCaptureKit expects display-local top-left points.
    public static func sourceRect(selection: CGRect, screen: CGRect) -> CGRect? {
        let clipped = selection.standardized.intersection(screen)
        guard !clipped.isNull, clipped.width >= 24, clipped.height >= 24 else { return nil }
        return CGRect(
            x: clipped.minX - screen.minX, y: screen.maxY - clipped.maxY,
            width: clipped.width, height: clipped.height)
    }

    public static func pixelSize(points: CGSize, scale: CGFloat, maxDimension: CGFloat = 3840) -> CGSize {
        let width = points.width * scale
        let height = points.height * scale
        let factor = min(1, maxDimension / max(width, height))
        // H.264 requires even output dimensions.
        return CGSize(
            width: max(2, floor(width * factor / 2) * 2),
            height: max(2, floor(height * factor / 2) * 2))
    }
}

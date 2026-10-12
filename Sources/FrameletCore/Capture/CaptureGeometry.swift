import CoreGraphics
import Foundation

/// Where a captured buffer sits on the desktop, and how its points map into encoded pixels.
/// Effects are recorded in global AppKit points (bottom-left origin) but painted into the
/// picture, which is cropped, scaled and top-left based; every conversion between the two
/// goes through this so a mark lands where it was drawn.
public struct CaptureProjection: Equatable {
    /// AppKit frame of the surface the buffer shows: the screen, or the window.
    public let frame: CGRect
    /// Crop inside the buffer, in top-left points.
    public let source: CGRect
    /// Point size of the buffer the crop applies to.
    public let bufferSize: CGSize
    /// Encoded pixel size.
    public let outputSize: CGSize

    public init(frame: CGRect, source: CGRect, bufferSize: CGSize, outputSize: CGSize) {
        self.frame = frame
        self.source = source
        self.bufferSize = bufferSize
        self.outputSize = outputSize
    }

    /// Horizontal output pixels per buffer point.
    public var scale: CGFloat { outputSize.width / max(1, source.width) }

    /// Output-pixel position of a global AppKit point, or nil when the point is outside the
    /// recorded area and its effect must not be painted at all.
    public func outputPoint(_ global: CGPoint) -> CGPoint? {
        let inBuffer = CGPoint(x: global.x - frame.minX, y: frame.maxY - global.y)
        // Inclusive bounds: the far edge belongs to the picture, an effect drawn exactly on it is
        // still visible. `CGRect.contains` excludes maxX/maxY, which would drop edge strokes.
        guard inBuffer.x >= source.minX, inBuffer.x <= source.maxX,
            inBuffer.y >= source.minY, inBuffer.y <= source.maxY
        else { return nil }
        return CGPoint(
            x: (inBuffer.x - source.minX) * scale,
            y: (inBuffer.y - source.minY) * outputSize.height / max(1, source.height))
    }

    /// Output-pixel length for a global point length, such as a stroke width.
    public func outputLength(_ points: CGFloat) -> CGFloat { points * scale }
}

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

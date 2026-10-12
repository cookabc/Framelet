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
    public static func sourceRect(selection: CGRect, screen: CGRect, minimumDimension: CGFloat = 24)
        -> CGRect?
    {
        let clipped = selection.standardized.intersection(screen)
        guard minimumDimension.isFinite, minimumDimension > 0,
            !clipped.isNull, clipped.width >= minimumDimension, clipped.height >= minimumDimension
        else { return nil }
        return CGRect(
            x: clipped.minX - screen.minX, y: screen.maxY - clipped.maxY,
            width: clipped.width, height: clipped.height)
    }

    /// Align inward so no pixels outside the selection are encoded. Keeping even pixel dimensions
    /// avoids shrinking an odd-width crop by a fraction and resampling every text edge.
    public static func alignedSourceRect(_ source: CGRect, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale > 0,
            [source.minX, source.minY, source.width, source.height].allSatisfy({ $0.isFinite }),
            source.width > 0, source.height > 0
        else { return nil }
        let x = ceil(source.minX * scale)
        let y = ceil(source.minY * scale)
        let width = floor((floor(source.maxX * scale) - x) / 2) * 2
        let height = floor((floor(source.maxY * scale) - y) / 2) * 2
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: x / scale, y: y / scale, width: width / scale, height: height / scale)
    }

    public static func alignedSelection(_ selection: CGRect, screen: CGRect, scale: CGFloat) -> CGRect? {
        guard
            let source = sourceRect(
                selection: selection, screen: screen, minimumDimension: 2 / max(1, scale)),
            let aligned = alignedSourceRect(source, scale: scale)
        else { return nil }
        return CGRect(
            x: screen.minX + aligned.minX, y: screen.maxY - aligned.maxY,
            width: aligned.width, height: aligned.height)
    }

    /// Movement keeps the take's locked size; only its origin snaps to the screen's pixel grid.
    public static func alignedMovement(_ selection: CGRect, screen: CGRect, scale: CGFloat) -> CGRect? {
        guard scale.isFinite, scale > 0, screen.contains(selection),
            [selection.minX, selection.minY, selection.width, selection.height].allSatisfy({ $0.isFinite })
        else { return nil }
        let x = screen.minX + ((selection.minX - screen.minX) * scale).rounded() / scale
        let top = screen.maxY - ((screen.maxY - selection.maxY) * scale).rounded() / scale
        let rect = CGRect(x: x, y: top - selection.height, width: selection.width, height: selection.height)
        return screen.contains(rect) ? rect : nil
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

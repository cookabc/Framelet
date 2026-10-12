import CoreGraphics
import Foundation

/// Draws `RecordingEffects` into an image already cropped to the recorded area. Everything is
/// sized in output pixels, so the same painter serves a small area on a Retina display and a full
/// window capture without knowing about either.
public enum OverlayPainter {
    /// The palette a pen stroke cycles through, chosen to read on both light and dark content.
    static let markColors: [CGColor] = [
        CGColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        CGColor(red: 1.00, green: 0.78, blue: 0.16, alpha: 1),
        CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1),
        CGColor(red: 0.16, green: 0.55, blue: 1.00, alpha: 1),
        CGColor(red: 0.81, green: 0.27, blue: 0.94, alpha: 1),
    ]

    /// A mark's points once projected. `nil` is a point that left the recorded area; the line
    /// breaks there instead of stretching to the edge.
    private typealias ProjectedPoints = [CGPoint?]

    public static func draw(
        _ snapshot: RecordingEffects.Snapshot, in context: CGContext, projection: CaptureProjection
    ) {
        // Projected points are top-left based — the same space the crop lives in — while a
        // CGContext counts up from the bottom. Flipping the context makes every drawing helper
        // below work in picture coordinates, and text still comes out upright.
        let height = projection.outputSize.height
        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        for mark in snapshot.marks {
            draw(mark, in: context, projection: projection)
        }
        context.restoreGState()
    }

    // MARK: - Marks

    private static func draw(
        _ mark: RecordingEffects.Mark, in context: CGContext, projection: CaptureProjection
    ) {
        let points = mark.points.map { projection.outputPoint($0) }
        let width = projection.outputLength(mark.width)
        let color = markColors[max(0, mark.colorIndex) % markColors.count]
        switch mark.stroke {
        case .pen, .highlighter:
            guard points.count >= 2 else { return }
            context.saveGState()
            if mark.stroke == .highlighter {
                context.setBlendMode(.multiply)
                context.setStrokeColor(color.copy(alpha: 0.35) ?? color)
                context.setLineWidth(width * 3)
            } else {
                context.setStrokeColor(color)
                context.setLineWidth(width)
            }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path(through: points))
            context.strokePath()
            context.restoreGState()
        case .arrow:
            // The arrow is tail to head, projected; both ends must be inside the recorded area.
            guard let tail = points.first ?? nil, let head = points.last ?? nil else { return }
            drawArrow(from: tail, to: head, width: width, color: color, in: context)
        }
    }

    /// One path per continuous run of on-screen points, so a stroke that leaves the area and
    /// returns is drawn as two segments rather than one jump across the picture.
    private static func path(through points: ProjectedPoints) -> CGPath {
        let path = CGMutablePath()
        var drawing = false
        for point in points {
            guard let point else {
                drawing = false
                continue
            }
            if drawing {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                drawing = true
            }
        }
        return path
    }

    private static func drawArrow(
        from start: CGPoint, to head: CGPoint, width: CGFloat, color: CGColor, in context: CGContext
    ) {
        let length = hypot(head.x - start.x, head.y - start.y)
        guard length > 1 else { return }
        let headLength = min(max(width * 4, 14), length)
        let angle = atan2(head.y - start.y, head.x - start.x)
        let spread = CGFloat.pi / 7
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // The shaft stops short of the tip so the head's point stays sharp at any width.
        let shaftEnd = CGPoint(
            x: head.x - cos(angle) * headLength * 0.85, y: head.y - sin(angle) * headLength * 0.85)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: shaftEnd)
        context.strokePath()
        let left = CGPoint(
            x: head.x - cos(angle - spread) * headLength, y: head.y - sin(angle - spread) * headLength)
        let right = CGPoint(
            x: head.x - cos(angle + spread) * headLength, y: head.y - sin(angle + spread) * headLength)
        context.beginPath()
        context.move(to: head)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

}

/// The annotation palette, exposed for the live preview so it uses exactly the colors the
/// recording will show.
public enum AnnotationColors {
    public static let markColors = OverlayPainter.markColors
}

import CoreGraphics
import Foundation

/// A take's annotations, in global AppKit points. The recorder and live drawing surface share
/// snapshots; mutations are serialized so the sample queue never reads a partially edited stroke.
public final class RecordingEffects: @unchecked Sendable {
    public enum Stroke: Sendable {
        case pen, highlighter, arrow
    }

    public struct Mark: Identifiable, Sendable {
        public let id: UUID
        public let stroke: Stroke
        public var points: [CGPoint]
        public let colorIndex: Int
        public let width: CGFloat
    }

    public struct Snapshot: Sendable {
        public let marks: [Mark]
        public let now: Double
        public let revision: UInt64
    }

    private let lock = NSLock()
    private var marks: [Mark] = []
    private var generation: UInt64 = 0

    public init() {}

    public var revision: UInt64 { lock.withLock { generation } }

    public func beginMark(stroke: Stroke, at point: CGPoint, colorIndex: Int, width: CGFloat) -> UUID {
        let id = UUID()
        lock.withLock {
            guard point.x.isFinite, point.y.isFinite, width.isFinite, width > 0 else { return }
            marks.append(
                Mark(id: id, stroke: stroke, points: [point], colorIndex: max(0, colorIndex), width: width))
            generation &+= 1
        }
        return id
    }

    public func extendMark(id: UUID, to point: CGPoint) {
        lock.withLock {
            guard point.x.isFinite, point.y.isFinite,
                let index = marks.firstIndex(where: { $0.id == id }), marks[index].points.last != point
            else { return }
            if marks[index].stroke == .arrow, marks[index].points.count == 2 {
                marks[index].points[1] = point
            } else {
                marks[index].points.append(point)
            }
            generation &+= 1
        }
    }

    public func finishMark(id: UUID) {
        lock.withLock {
            if let index = marks.firstIndex(where: { $0.id == id }), marks[index].points.count < 2 {
                marks.remove(at: index)
                generation &+= 1
            }
        }
    }

    public func undo() {
        lock.withLock {
            guard !marks.isEmpty else { return }
            marks.removeLast()
            generation &+= 1
        }
    }

    public func clear() {
        lock.withLock {
            guard !marks.isEmpty else { return }
            marks.removeAll()
            generation &+= 1
        }
    }

    public func snapshot(at time: Double) -> Snapshot {
        lock.withLock { Snapshot(marks: marks, now: time, revision: generation) }
    }
}

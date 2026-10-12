import CoreGraphics
import XCTest

@testable import FrameletCore

final class RecordingEffectsTests: XCTestCase {
    func testTapIsDroppedAndUndoRemovesOnlyTheLastMark() {
        let effects = RecordingEffects()
        let tap = effects.beginMark(stroke: .pen, at: .zero, colorIndex: 0, width: 3)
        effects.extendMark(id: tap, to: .zero)
        effects.finishMark(id: tap)
        XCTAssertTrue(effects.snapshot(at: 0).marks.isEmpty)
        let first = effects.beginMark(stroke: .pen, at: .zero, colorIndex: 0, width: 3)
        effects.extendMark(id: first, to: CGPoint(x: 10, y: 0))
        let second = effects.beginMark(stroke: .arrow, at: .zero, colorIndex: 1, width: 3)
        effects.extendMark(id: second, to: CGPoint(x: 0, y: 10))
        effects.undo()
        XCTAssertEqual(effects.snapshot(at: 0).marks.map(\.id), [first])
        effects.clear()
        XCTAssertTrue(effects.snapshot(at: 0).marks.isEmpty)
    }

    func testArrowRetainsOnlyEndpointsAndRevisionsIncludeClear() {
        let effects = RecordingEffects()
        let id = effects.beginMark(stroke: .arrow, at: .zero, colorIndex: 0, width: 3)
        for x in 1...100 { effects.extendMark(id: id, to: CGPoint(x: x, y: x)) }
        let before = effects.snapshot(at: 0)
        XCTAssertEqual(before.marks.first?.points, [.zero, CGPoint(x: 100, y: 100)])
        effects.clear()
        XCTAssertGreaterThan(effects.revision, before.revision)
        XCTAssertTrue(effects.snapshot(at: 0).marks.isEmpty)
    }

    func testInvalidStrokeInputsDoNotReachPainter() {
        let effects = RecordingEffects()
        _ = effects.beginMark(stroke: .pen, at: CGPoint(x: CGFloat.nan, y: 0), colorIndex: 0, width: 3)
        _ = effects.beginMark(stroke: .pen, at: .zero, colorIndex: 0, width: -.infinity)
        XCTAssertTrue(effects.snapshot(at: 0).marks.isEmpty)
        let id = effects.beginMark(stroke: .pen, at: .zero, colorIndex: -99, width: 3)
        effects.extendMark(id: id, to: CGPoint(x: CGFloat.infinity, y: 1))
        XCTAssertEqual(effects.snapshot(at: 0).marks.first?.points.count, 1)
        XCTAssertEqual(effects.snapshot(at: 0).marks.first?.colorIndex, 0)
    }
}

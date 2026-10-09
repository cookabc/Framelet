import XCTest

@testable import FrameletCore

final class RecordingClockTests: XCTestCase {
    func testPauseResumeExcludesLongPausesAndRestartResetsTime() {
        var clock = RecordingClock()
        clock.resume(at: 10)
        clock.resume(at: 11)
        clock.pause(at: 15)
        clock.pause(at: 90)
        XCTAssertEqual(clock.elapsed(at: 100), 5)
        clock.resume(at: 200)
        XCTAssertEqual(clock.elapsed(at: 202), 7)
        clock.pause(at: 203)
        XCTAssertEqual(clock.elapsed(at: 300), 8)
        clock.reset()
        XCTAssertEqual(clock.elapsed(at: 500), 0)
        clock.resume(at: 600)
        XCTAssertEqual(clock.elapsed(at: 601), 1)
    }
}

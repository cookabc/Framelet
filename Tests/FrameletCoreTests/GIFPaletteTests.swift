import XCTest

@testable import FrameletCore

final class GIFPaletteTests: XCTestCase {
    func testFewDistinctBinsUseOriginalRGBRatherThanBinEndpoints() throws {
        var histogram: GIFPalette.Histogram = [:]
        for _ in 0..<500 {
            GIFPalette.accumulate(red: 17, green: 34, blue: 51, into: &histogram)
            GIFPalette.accumulate(red: 250, green: 240, blue: 230, into: &histogram)
        }
        var palette = try GIFPalette.build(histogram: histogram)
        XCTAssertEqual(palette.colorTable.count, 6)
        let first = palette.color(at: palette.index(for: 17, green: 34, blue: 51))
        let second = palette.color(at: palette.index(for: 250, green: 240, blue: 230))
        XCTAssertEqual([first.red, first.green, first.blue], [17, 34, 51])
        XCTAssertEqual([second.red, second.green, second.blue], [250, 240, 230])
    }

    func testColorsSharingBinUseOriginalPopulationWeightedMean() throws {
        var histogram: GIFPalette.Histogram = [:]
        for _ in 0..<3 { GIFPalette.accumulate(red: 17, green: 34, blue: 51, into: &histogram) }
        GIFPalette.accumulate(red: 23, green: 39, blue: 55, into: &histogram)
        let palette = try GIFPalette.build(histogram: histogram)
        XCTAssertEqual(palette.colorTable, [18, 35, 52])
    }

    func testRichHistogramIsDeterministicAndCapsAt256Colors() throws {
        var forward: GIFPalette.Histogram = [:]
        var reverse: GIFPalette.Histogram = [:]
        let values: [(UInt8, UInt8, UInt8)] = (0..<600).map { value in
            let red = UInt8((value / 60) * 25)
            let green = UInt8((value / 6 % 10) * 25)
            let blue = UInt8((value % 6) * 45)
            return (red, green, blue)
        }
        for value in values {
            GIFPalette.accumulate(red: value.0, green: value.1, blue: value.2, into: &forward)
        }
        for value in values.reversed() {
            GIFPalette.accumulate(red: value.0, green: value.1, blue: value.2, into: &reverse)
        }
        var a = try GIFPalette.build(histogram: forward)
        var b = try GIFPalette.build(histogram: reverse)
        XCTAssertEqual(a.colorTable.count, 256 * 3)
        XCTAssertEqual(a.colorTable, b.colorTable)
        for value in values {
            XCTAssertEqual(
                a.index(for: value.0, green: value.1, blue: value.2),
                b.index(for: value.0, green: value.1, blue: value.2))
        }
    }

    func testUnseenBinCacheDoesNotDependOnFirstPixel() throws {
        var histogram: GIFPalette.Histogram = [:]
        GIFPalette.accumulate(red: 0, green: 0, blue: 0, into: &histogram)
        GIFPalette.accumulate(red: 24, green: 0, blue: 0, into: &histogram)
        var a = try GIFPalette.build(histogram: histogram)
        var b = try GIFPalette.build(histogram: histogram)
        let a8 = a.index(for: 8, green: 0, blue: 0)
        let a15 = a.index(for: 15, green: 0, blue: 0)
        let b15 = b.index(for: 15, green: 0, blue: 0)
        let b8 = b.index(for: 8, green: 0, blue: 0)
        XCTAssertEqual(a8, b8)
        XCTAssertEqual(a15, b15)
        XCTAssertEqual(
            a8, a15, "LUT uses one deterministic representative per bin, not exact per-pixel nearest color")
    }

    func testSampledBinsMapToNearestPaletteRepresentative() throws {
        var histogram: GIFPalette.Histogram = [:]
        for value in 0..<600 {
            GIFPalette.accumulate(
                red: UInt8(value % 256), green: UInt8(value / 256 * 90),
                blue: UInt8(value % 31 * 8), into: &histogram)
        }
        var palette = try GIFPalette.build(histogram: histogram)
        for sample in histogram.values {
            let rgb = [sample.red / sample.count, sample.green / sample.count, sample.blue / sample.count]
            let entry = palette.index(for: UInt8(rgb[0]), green: UInt8(rgb[1]), blue: UInt8(rgb[2]))
            let color = palette.color(at: entry)
            func distance(_ color: [UInt8]) -> Int {
                zip(rgb, color).reduce(0) { total, pair in
                    total + (pair.0 - Int(pair.1)) * (pair.0 - Int(pair.1))
                }
            }
            let selected = distance([color.red, color.green, color.blue])
            for index in 0..<(palette.colorTable.count / 3) {
                let other = palette.color(at: UInt8(index))
                XCTAssertLessThanOrEqual(selected, distance([other.red, other.green, other.blue]))
            }
        }
    }

    func testEmptyHistogramProducesUsableBlackPalette() throws {
        var palette = try GIFPalette.build(histogram: [:])
        XCTAssertEqual(palette.colorTable, [0, 0, 0])
        XCTAssertEqual(palette.index(for: 10, green: 20, blue: 30), 0)
    }

    func testCancelledPaletteBuildThrows() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GIFPalette.build(histogram: [:])
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled palette build must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

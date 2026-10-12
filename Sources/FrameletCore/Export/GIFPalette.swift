import CoreGraphics
import Foundation

/// A shared, content-adaptive palette. The histogram groups RGB into 5-bit channels,
/// but representatives use the original RGB sums, not artificial bin endpoints.
/// Both binning and the 256-color limit can still introduce quantization error.
struct GIFPalette {
    struct Sample {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0

        mutating func add(red: UInt8, green: UInt8, blue: UInt8) {
            count += 1
            self.red += Int(red)
            self.green += Int(green)
            self.blue += Int(blue)
        }
    }

    typealias Histogram = [Int: Sample]
    private struct Bin {
        let key: Int
        let sample: Sample

        func channel(_ axis: Int) -> Int {
            switch axis {
            case 0: return sample.red / sample.count
            case 1: return sample.green / sample.count
            default: return sample.blue / sample.count
            }
        }
    }

    private struct Box {
        var bins: [Int]
        var population: Int
    }

    private var colors: [(red: UInt8, green: UInt8, blue: UInt8)] = []
    // Dense, lazy LUT. A bin always uses its sampled mean (or fixed center if unseen),
    // so mapping never depends on which pixel happened to be encountered first.
    private var entries = [Int16](repeating: -1, count: 1 << 15)

    var colorTable: [UInt8] {
        colors.flatMap { [$0.red, $0.green, $0.blue] }
    }

    func color(at index: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8) {
        colors[Int(index)]
    }

    static func key(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        (Int(red) >> 3) << 10 | (Int(green) >> 3) << 5 | (Int(blue) >> 3)
    }

    static func accumulate(red: UInt8, green: UInt8, blue: UInt8, into histogram: inout Histogram) {
        histogram[key(red: red, green: green, blue: blue), default: Sample()].add(
            red: red, green: green, blue: blue)
    }

    static func build(histogram: Histogram) throws -> GIFPalette {
        try Task.checkCancellation()
        var palette = GIFPalette()
        let bins = histogram.keys.sorted().compactMap { key -> Bin? in
            guard let sample = histogram[key], sample.count > 0 else { return nil }
            return Bin(key: key, sample: sample)
        }
        guard !bins.isEmpty else {
            palette.colors = [(0, 0, 0)]
            return palette
        }
        var boxes = [Box(bins: Array(bins.indices), population: bins.reduce(0) { $0 + $1.sample.count })]
        while boxes.count < 256 {
            try Task.checkCancellation()
            // First box wins population ties; sorted bins and explicit sort tie-breakers
            // make the palette independent of Dictionary iteration order.
            var selected: Int?
            for index in boxes.indices where boxes[index].bins.count > 1 {
                if selected == nil || boxes[index].population > boxes[selected!].population {
                    selected = index
                }
            }
            guard let selected else { break }
            let box = boxes[selected]
            var minima = [Int.max, Int.max, Int.max]
            var maxima = [Int.min, Int.min, Int.min]
            for index in box.bins {
                for axis in 0..<3 {
                    minima[axis] = min(minima[axis], bins[index].channel(axis))
                    maxima[axis] = max(maxima[axis], bins[index].channel(axis))
                }
            }
            var axis = 0
            for candidate in 1..<3 where maxima[candidate] - minima[candidate] > maxima[axis] - minima[axis] {
                axis = candidate
            }
            let sorted = box.bins.sorted {
                let lhs = bins[$0].channel(axis)
                let rhs = bins[$1].channel(axis)
                return lhs == rhs ? bins[$0].key < bins[$1].key : lhs < rhs
            }
            var split = 1
            var population = bins[sorted[0]].sample.count
            while split < sorted.count - 1 && population < (box.population + 1) / 2 {
                population += bins[sorted[split]].sample.count
                split += 1
            }
            boxes[selected] = Box(bins: Array(sorted[..<split]), population: population)
            boxes.append(Box(bins: Array(sorted[split...]), population: box.population - population))
        }
        palette.colors = boxes.map { box in
            var red = 0
            var green = 0
            var blue = 0
            for index in box.bins {
                red += bins[index].sample.red
                green += bins[index].sample.green
                blue += bins[index].sample.blue
            }
            return (
                UInt8(red / box.population), UInt8(green / box.population), UInt8(blue / box.population)
            )
        }
        for (index, bin) in bins.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            palette.entries[bin.key] = Int16(
                palette.nearest(
                    red: bin.channel(0), green: bin.channel(1), blue: bin.channel(2)))
        }
        return palette
    }

    mutating func index(for red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        let key = Self.key(red: red, green: green, blue: blue)
        if entries[key] >= 0 { return UInt8(entries[key]) }
        let entry = nearest(
            red: (key >> 10 & 31) * 8 + 4,
            green: (key >> 5 & 31) * 8 + 4,
            blue: (key & 31) * 8 + 4)
        entries[key] = Int16(entry)
        return entry
    }

    private func nearest(red: Int, green: Int, blue: Int) -> UInt8 {
        var best = 0
        var distance = Int.max
        for (index, color) in colors.enumerated() {
            let dr = red - Int(color.red)
            let dg = green - Int(color.green)
            let db = blue - Int(color.blue)
            let candidate = dr * dr + dg * dg + db * db
            if candidate < distance {
                distance = candidate
                best = index
            }
        }
        return UInt8(best)
    }
}

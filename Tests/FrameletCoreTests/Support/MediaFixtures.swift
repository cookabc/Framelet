import AVFoundation
import XCTest

func makeTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FrameletTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func samplePixel(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

func makeTestVideo(in directory: URL, width: Int = 160) async throws -> URL {
    let url = directory.appendingPathComponent("synthetic.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: 90,
        ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: 90,
        ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<40 {
        var retries = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error! }
            retries += 1
            guard retries < 500 else { throw NSError(domain: "TestWriter", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer), kCVReturnSuccess)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<90 {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                base[offset] = 255
                base[offset + 1] = frame < 20 ? 240 : 20
                base[offset + 2] = 70
                base[offset + 3] = frame < 20 ? 20 : 240
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)))
    }
    writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return url
}

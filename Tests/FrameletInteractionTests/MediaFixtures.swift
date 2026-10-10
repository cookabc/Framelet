import AVFoundation
import XCTest

/// Writes a short real H.264 clip. Recovery tests need genuinely decodable segments; a plain file
/// would be discarded as unusable before assembly ever runs.
func makeRecoverySegment(in directory: URL, width: Int = 160) async throws -> URL {
    let url = directory.appendingPathComponent("segment-\(UUID().uuidString).mp4")
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
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: 90,
        ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<8 {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error! }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The adaptor's pool is not guaranteed to exist this early; a hand-made buffer appends fine.
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, width, 90, kCVPixelFormatType_32ARGB,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        else {
            throw NSError(
                domain: "TestWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "append failed: \(String(describing: writer.error))"])
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    return url
}

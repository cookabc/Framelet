import AVFoundation

public enum SessionAssemblyError: LocalizedError {
    case noVideo, incompatibleSegments, exportUnavailable
    public var errorDescription: String? {
        switch self {
        case .noVideo: return "没有可用的视频片段。"
        case .incompatibleSegments: return "录制片段的画面尺寸不同，无法合并。原始片段已保留。"
        case .exportUnavailable: return "无法合并录制。原始片段已保留，可以重新尝试。"
        }
    }
}

public enum SessionAssembler {
    /// Capture pauses close a segment. Joining just their media ranges eliminates the pause gaps.
    /// All segments are silent and use the output dimensions locked at the beginning of the take.
    public static func assemble(segments: [URL], to output: URL) async throws {
        guard !segments.isEmpty else { throw SessionAssemblyError.noVideo }
        let composition = AVMutableComposition()
        guard
            let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw SessionAssemblyError.exportUnavailable
        }
        var cursor = CMTime.zero
        var size: CGSize?
        for url in segments {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw SessionAssemblyError.noVideo
            }
            let range = try await track.load(.timeRange)
            let currentSize = try await track.load(.naturalSize)
            guard range.duration.isNumeric, range.duration.seconds > 0 else {
                throw SessionAssemblyError.noVideo
            }
            if let size, size != currentSize { throw SessionAssemblyError.incompatibleSegments }
            if size == nil { video.preferredTransform = try await track.load(.preferredTransform) }
            size = currentSize
            try video.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }
        let staged = FileExport.stagingURL(for: output)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard
            let exporter = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetPassthrough)
        else {
            throw SessionAssemblyError.exportUnavailable
        }
        try await exporter.export(to: staged, as: .mp4)
        try Task.checkCancellation()
        try FileExport.commit(staged, to: output)
    }
}

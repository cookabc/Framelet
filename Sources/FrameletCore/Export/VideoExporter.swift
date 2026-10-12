import AVFoundation
import Foundation

public enum VideoExportError: LocalizedError {
    case invalidRange, invalidDestination, unsupportedVideo, exportFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "Choose a positive time range entirely inside the video."
        case .invalidDestination:
            return "Choose a different destination. The original recording cannot be overwritten."
        case .unsupportedVideo:
            return
                "This video cannot be exported as MP4 without re-encoding. The original recording was kept."
        case .exportFailed:
            return "The video could not be exported. The original recording was kept."
        }
    }
}

/// Non-destructive, silent MP4 export without re-encoding. Passthrough is not a
/// promise of arbitrary frame-accurate cuts for every codec/GOP structure.
public enum VideoExporter {
    public static func export(video: URL, to output: URL, start: Double, duration: Double) async throws {
        try Task.checkCancellation()
        guard video.isFileURL, output.isFileURL, !exportTargetsSource(video, output) else {
            throw VideoExportError.invalidDestination
        }
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0,
            (start + duration).isFinite
        else { throw VideoExportError.invalidRange }
        let asset = AVURLAsset(url: video)
        let assetDuration = try await asset.load(.duration)
        let total = assetDuration.seconds
        guard total.isFinite, start + duration <= total else { throw VideoExportError.invalidRange }
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard videos.count == 1, let sourceTrack = videos.first else {
            throw VideoExportError.unsupportedVideo
        }
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60000),
            duration: CMTime(seconds: duration, preferredTimescale: 60000))
        let trackRange = try await sourceTrack.load(.timeRange)
        guard range.duration > .zero, range.start >= trackRange.start,
            range.end <= trackRange.end, range.end <= assetDuration
        else { throw VideoExportError.invalidRange }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
        if start == 0, duration == total, audio.isEmpty, video.pathExtension.lowercased() == "mp4" {
            let copyTask = Task.detached {
                try Task.checkCancellation()
                guard !exportTargetsSource(video, output) else { throw VideoExportError.invalidDestination }
                try FileExport.copyVideo(from: video, to: output)
            }
            try await withTaskCancellationHandler {
                try await copyTask.value
            } onCancel: {
                copyTask.cancel()
            }
            return
        }
        // Deliberately include only the video track, even when the input has audio.
        let composition = AVMutableComposition()
        guard
            let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoExportError.unsupportedVideo }
        try track.insertTimeRange(range, of: sourceTrack, at: .zero)
        track.preferredTransform = try await sourceTrack.load(.preferredTransform)
        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetPassthrough),
            session.supportedFileTypes.contains(.mp4)
        else { throw VideoExportError.unsupportedVideo }
        let staged = FileExport.stagingURL(for: output)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await session.export(to: staged, as: .mp4)
            } onCancel: {
                session.cancelExport()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard !exportTargetsSource(video, output) else { throw VideoExportError.invalidDestination }
        try FileExport.commit(staged, to: output)
    }
}

/// Resolve symlinks and detect existing hard links before staging or committing.
/// UI callers should still choose a fresh destination rather than export over the source.
func exportTargetsSource(_ source: URL, _ destination: URL) -> Bool {
    if source.resolvingSymlinksInPath().standardizedFileURL
        == destination.resolvingSymlinksInPath().standardizedFileURL
    {
        return true
    }
    guard let lhs = try? FileManager.default.attributesOfItem(atPath: source.path),
        let rhs = try? FileManager.default.attributesOfItem(atPath: destination.path),
        let lhsFile = lhs[.systemFileNumber] as? NSNumber,
        let rhsFile = rhs[.systemFileNumber] as? NSNumber,
        let lhsDevice = lhs[.systemNumber] as? NSNumber,
        let rhsDevice = rhs[.systemNumber] as? NSNumber
    else { return false }
    return lhsFile == rhsFile && lhsDevice == rhsDevice
}

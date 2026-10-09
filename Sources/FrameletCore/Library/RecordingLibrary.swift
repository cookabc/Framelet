import Foundation

public enum RecordingLibrary {
    public static func moveToTrash(
        _ file: URL, in directory: URL,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == root.path,
            resolved.pathExtension.lowercased() == "mp4"
        else {
            throw NSError(domain: "Framelet", code: 4, userInfo: [NSLocalizedDescriptionKey: "只能删除录制列表中的视频。"])
        }
        try trash(file)
    }
}

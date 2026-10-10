import Foundation

public enum RecordingLibrary {
    /// Holds the segments of a take that has not been joined into a recording yet.
    public static let sessionFolderName = "未完成录制"

    public static func sessionContainer(in library: URL) -> URL {
        library.appendingPathComponent(sessionFolderName, isDirectory: true)
    }

    public static func newSessionURL(in library: URL) -> URL {
        sessionContainer(in: library).appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Session folders left behind by takes that never finished, oldest first.
    public static func unfinishedSessions(in library: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: sessionContainer(in: library), includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        return entries.filter(isDirectory).sorted { creationDate(of: $0) < creationDate(of: $1) }
    }

    /// The segments of a take, in the order they must be joined: a pause closes one segment and
    /// opens the next, so creation order is playback order. Zero-length files are the debris of a
    /// take that failed before the encoder wrote anything and are not returned.
    public static func usableSegments(in session: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: session, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return
            entries
            .filter { $0.pathExtension.lowercased() == "mp4" && fileSize(of: $0) > 0 }
            .sorted {
                let left = creationDate(of: $0)
                let right = creationDate(of: $1)
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
    }

    /// Deletes one session folder and, once it is gone, the folder that contained it.
    /// Confined to `library` so a stray path cannot delete anything else.
    public static func removeSession(_ session: URL, in library: URL) {
        let container = sessionContainer(in: library).standardizedFileURL
        guard session.standardizedFileURL.deletingLastPathComponent().path == container.path else { return }
        try? FileManager.default.removeItem(at: session)
        guard let remaining = try? FileManager.default.contentsOfDirectory(atPath: container.path),
            remaining.isEmpty
        else { return }
        try? FileManager.default.removeItem(at: container)
    }

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

    private static func creationDate(of url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate) ?? .distantPast
    }

    private static func fileSize(of url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }

    private static func isDirectory(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
    }
}

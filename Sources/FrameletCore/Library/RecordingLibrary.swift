import Foundation

public enum RecordingLibrary {
    /// Holds the segments of a take that has not been joined into a recording yet.
    public static let sessionFolderName = "Unfinished"

    /// Takes recorded before the folder was renamed to `Unfinished` left their sessions here.
    public static let legacySessionFolderName = "未完成录制"

    public static func sessionContainer(in library: URL) -> URL {
        library.appendingPathComponent(sessionFolderName, isDirectory: true)
    }

    /// Every folder that can hold unfinished sessions, current name first.
    public static func sessionContainers(in library: URL) -> [URL] {
        [
            sessionContainer(in: library),
            library.appendingPathComponent(legacySessionFolderName, isDirectory: true),
        ]
    }

    public static func newSessionURL(in library: URL) -> URL {
        sessionContainer(in: library).appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Session folders left behind by takes that never finished, oldest first. Both container names
    /// are scanned so a take recorded by an older build is still recovered.
    public static func unfinishedSessions(in library: URL) -> [URL] {
        let entries = sessionContainers(in: library).flatMap { container in
            (try? FileManager.default.contentsOfDirectory(
                at: container, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        }
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

    /// A failed listing or unreadable file is not evidence that a session is empty.
    public static func isEmptySession(_ session: URL) -> Bool {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: session, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [])
        else { return false }
        return files.allSatisfy { file in
            guard file.pathExtension.lowercased() == "mp4",
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true, let size = values.fileSize
            else { return false }
            return size == 0
        }
    }

    /// Recovery consumes only the segments it joined; unrelated files in the session survive.
    public static func removeRecoveredSegments(_ segments: [URL], in session: URL, library: URL) {
        let parents = Set(sessionContainers(in: library).map { $0.standardizedFileURL.path })
        guard parents.contains(session.standardizedFileURL.deletingLastPathComponent().path) else { return }
        for segment in segments {
            guard segment.standardizedFileURL.deletingLastPathComponent() == session.standardizedFileURL,
                segment.pathExtension.lowercased() == "mp4"
            else { continue }
            try? FileManager.default.removeItem(at: segment)
        }
        removeEmptySession(session, in: library)
    }

    public static func removeEmptySession(_ session: URL, in library: URL) {
        guard let remaining = try? FileManager.default.contentsOfDirectory(atPath: session.path),
            remaining.isEmpty
        else { return }
        removeSession(session, in: library)
    }

    /// Deletes one session folder and, once it is gone, the container that held it.
    /// Confined to `library` so a stray path cannot delete anything else.
    public static func removeSession(_ session: URL, in library: URL) {
        let parents = Set(sessionContainers(in: library).map { $0.standardizedFileURL.path })
        guard parents.contains(session.standardizedFileURL.deletingLastPathComponent().path) else {
            return
        }
        try? FileManager.default.removeItem(at: session)
        pruneEmptySessionContainers(in: library)
    }

    /// Removes each container once it holds nothing, so an empty folder is not left behind in the
    /// library. Containers are created lazily, so a take that succeeds on its first attempt would
    /// otherwise leave them there for good.
    public static func pruneEmptySessionContainers(in library: URL) {
        for container in sessionContainers(in: library) {
            guard
                let remaining = try? FileManager.default.contentsOfDirectory(atPath: container.path),
                remaining.isEmpty
            else { continue }
            try? FileManager.default.removeItem(at: container)
        }
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
            throw NSError(
                domain: "Framelet", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Only recordings in the library can be deleted."])
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

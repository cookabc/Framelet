import Foundation

public enum FileExport {
    /// Stage beside the destination so a failed export never truncates an existing user file.
    public static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".framelet-\(UUID().uuidString).\(destination.pathExtension)")
    }

    public static func commit(_ staged: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    public static func copyVideo(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let staged = stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        try commit(staged, to: destination)
    }
}

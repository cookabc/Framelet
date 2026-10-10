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
        try copyCancellable(from: source, to: staged)
        try Task.checkCancellation()
        try commit(staged, to: destination)
    }

    /// A recording can be gigabytes, so the copy checks for cancellation between chunks.
    /// `FileManager.copyItem` would run to completion before the caller could ever notice.
    private static func copyCancellable(from source: URL, to destination: URL) throws {
        guard let input = InputStream(url: source) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: source])
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        input.open()
        defer { input.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                if count < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
                return
            }
            try output.write(contentsOf: buffer[0..<count])
        }
    }
}

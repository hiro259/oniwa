import Foundation

/// Minimal local-only diagnostic trace for failures in macOS's undocumented
/// synthetic Space-switch routing. Stores the visible name of the selected
/// Space, app PROCESS names and abbreviated Space UUIDs to troubleshoot a
/// mismatched result. Does not store window titles, search queries or keys.
/// Log is local and never uploaded; do not share it without reviewing contents.
enum SpaceSwitchDiagnostics {
    private static let writeLock = NSLock()

    /// Prevent line breaks, terminal control characters and unbounded labels
    /// from introducing forged log entries or bloating the trace.
    static func safe(_ text: String) -> String {
        text.unicodeScalars.prefix(100).map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
    }

    static let logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ONIWA/switch.log")
    }()

    static func record(_ message: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let manager = FileManager.default
        let directory = logURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: Date())
            let line = "\(stamp) \(message)\n"
            let data = Data(line.utf8)
            if !manager.fileExists(atPath: logURL.path) {
                manager.createFile(atPath: logURL.path, contents: data)
            } else {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            // Retain only recent activity. Never let traces fill the disk.
            let attributes = try manager.attributesOfItem(atPath: logURL.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > 256 * 1024 {
                let contents = try Data(contentsOf: logURL)
                try Data(contents.suffix(128 * 1024)).write(to: logURL, options: .atomic)
            }
        } catch {
            // Diagnostic logging must never interrupt a Space switch.
        }
    }

    static func shortDisplay(_ id: String) -> String {
        String(id.prefix(8))
    }
}

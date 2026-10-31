import AppKit
import Foundation

/// Minimal local-only diagnostic trace for failures in macOS's undocumented
/// synthetic Space-switch routing. Stores the visible name of the selected
/// Space, app PROCESS names and abbreviated Space UUIDs to troubleshoot a
/// mismatched result. Does not store window titles, search queries or keys.
/// Log is local and never uploaded; do not share it without reviewing contents.
enum SpaceSwitchDiagnostics {
    private static let writeLock = NSLock()
    private static let traceLock = NSLock()
    private static var activeSwitches = 0
    private static var traceUntilUptime: TimeInterval = 0

    /// Restrict Workspace event logging to an ONIWA switch and the 1.5 seconds
    /// after it returns. This also captures delayed moves after the 850ms
    /// settled check, without logging unrelated application activity all day.
    static func beginWorkspaceTrace() {
        traceLock.lock()
        activeSwitches += 1
        traceLock.unlock()
        record("workspace-trace begin")
    }

    static func endWorkspaceTrace() {
        traceLock.lock()
        activeSwitches = max(0, activeSwitches - 1)
        traceUntilUptime = ProcessInfo.processInfo.systemUptime + 1.5
        traceLock.unlock()
        record("workspace-trace end tail=1500ms")
    }

    static var workspaceTraceEnabled: Bool {
        traceLock.lock()
        defer { traceLock.unlock() }
        return activeSwitches > 0
            || ProcessInfo.processInfo.systemUptime <= traceUntilUptime
    }

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
            let uptimeMS = Int64(ProcessInfo.processInfo.systemUptime * 1000)
            let line = "\(stamp) uptimeMs=\(uptimeMS) \(message)\n"
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

/// Diagnostic-only AppKit observers. The notifications mark an observed change,
/// not a Dock/WindowServer transition-completion acknowledgement.
/// Keep callbacks lightweight and do not activate any applications.
final class SpaceWorkspaceEventObserver {
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.capture("space-changed", application: nil)
        })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.capture("app-activated", application: application)
        })
    }

    deinit {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func capture(_ kind: String, application: NSRunningApplication?) {
        // Capture callback time before reading the layout. Notification delivery
        // is asynchronous relative to the underlying Dock transition.
        let callbackMS = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        guard SpaceSwitchDiagnostics.workspaceTraceEnabled else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let displays = SpaceReader.shared.displays(includeAppNames: false)
        let sampleMS = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        let ids = displays.map { group in
            "\(SpaceSwitchDiagnostics.shortDisplay(group.id)):"
                + "\(group.currentID.map(String.init) ?? "unknown")"
        }.joined(separator: ",")
        let source = application?.bundleIdentifier.map(SpaceSwitchDiagnostics.safe) ?? "none"
        let active = frontmost?.bundleIdentifier.map(SpaceSwitchDiagnostics.safe) ?? "none"
        SpaceSwitchDiagnostics.record(
            "workspace-event kind=\(kind) callbackUptimeMs=\(callbackMS) "
            + "sampleUptimeMs=\(sampleMS) "
            + "activated=\(source) activatedPid=\(application?.processIdentifier ?? 0) "
            + "frontmost=\(active) frontmostPid=\(frontmost?.processIdentifier ?? 0) "
            + "displays=[\(ids)]"
        )
    }
}

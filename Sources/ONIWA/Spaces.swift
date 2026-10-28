import AppKit
import CoreGraphics
import Foundation
import ONIWACore

struct SpaceEntry: Identifiable, Hashable {
    let id: String
    let systemID: UInt64
    let displayID: String
    let displayName: String
    let index: Int
    let kind: Int
    let isCurrent: Bool
    let appNames: [String]

    var defaultName: String {
        if kind == 4, let app = appNames.first { return app }
        return kind == 4 ? "Full Screen \(index + 1)" : "Desktop \(index + 1)"
    }
}

struct DisplayGroup {
    let id: String
    let name: String
    let currentID: UInt64?
    let spaces: [SpaceEntry]
}

struct CustomLabel: Codable {
    var name: String
    var aliases: String
}

/// Labels are stored by Space UUID (with a positional fallback when UUID is empty).
/// Fullscreen Space UUIDs are not guaranteed to survive closing/reopening an app.
final class LabelStore {
    private let key = "oniwa.customLabels.v1"
    private var records: [String: CustomLabel] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: CustomLabel].self, from: data) {
            records = saved
        }
    }

    func label(for item: SpaceEntry) -> CustomLabel? { records[item.id] }

    func set(_ item: SpaceEntry, name: String, aliases: String) {
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let cleanAliases = String(aliases.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250))
        if cleanName.isEmpty && cleanAliases.isEmpty {
            records.removeValue(forKey: item.id)
        } else {
            records[item.id] = CustomLabel(name: cleanName, aliases: cleanAliases)
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Read-only private SkyLight API. Failure returns no Spaces, never false success.
final class SpaceReader {
    static let shared = SpaceReader()
    typealias ConnectionFn = @convention(c) () -> Int32
    typealias LayoutFn = @convention(c) (Int32) -> CFArray?
    typealias WindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private let handle: UnsafeMutableRawPointer?
    private let connectionFn: ConnectionFn?
    private let layoutFn: LayoutFn?
    private let windowsFn: WindowsFn?

    var available: Bool { connectionFn != nil && layoutFn != nil }

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        self.handle = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connectionFn = symbol("CGSMainConnectionID", ConnectionFn.self)
        layoutFn = symbol("CGSCopyManagedDisplaySpaces", LayoutFn.self)
        windowsFn = symbol("CGSCopySpacesForWindows", WindowsFn.self)
    }

    func displays() -> [DisplayGroup] {
        guard let connectionFn, let layoutFn,
              let raw = layoutFn(connectionFn()) as? [[String: Any]] else { return [] }

        let ownerNames = windowOwners(connection: connectionFn())
        return raw.enumerated().compactMap { displayIndex, display in
            guard let displayID = display["Display Identifier"] as? String,
                  let spaceDicts = display["Spaces"] as? [[String: Any]] else { return nil }
            let name = displayName(displayID, fallback: displayIndex + 1)
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            let spaces: [SpaceEntry] = spaceDicts.enumerated().compactMap { index, record in
                guard let number = (record["ManagedSpaceID"] as? NSNumber)
                        ?? (record["id64"] as? NSNumber) else { return nil }
                let id = number.uint64Value
                let uuid = record["uuid"] as? String ?? ""
                // Do not persist the volatile numeric Space ID.
                let key = uuid.isEmpty ? "position:\(displayID):\(index)" : "uuid:\(uuid)"
                let kind = (record["type"] as? NSNumber)?.intValue ?? 0
                return SpaceEntry(id: key, systemID: id, displayID: displayID,
                                  displayName: name, index: index, kind: kind,
                                  isCurrent: current?.uint64Value == id,
                                  appNames: ownerNames[id] ?? [])
            }
            return DisplayGroup(id: displayID, name: name,
                                currentID: current?.uint64Value, spaces: spaces)
        }
    }

    private func windowOwners(connection: Int32) -> [UInt64: [String]] {
        guard let windowsFn,
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var names: [UInt64: Set<String>] = [:]
        for info in windows {
            guard let id = info[kCGWindowNumber as String] as? NSNumber,
                  let appName = info[kCGWindowOwnerName as String] as? String,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let spaceIDs = windowsFn(connection, 0x7, [id.intValue] as CFArray) as? [NSNumber]
            else { continue }
            for spaceID in spaceIDs where spaceIDs.count == 1 {
                names[spaceID.uint64Value, default: []].insert(appName)
            }
        }
        return names.mapValues { $0.sorted() }
    }

    private func displayName(_ uuid: String, fallback: Int) -> String {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let displayUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
            else { continue }
            let value = CFUUIDCreateString(nil, displayUUID.takeRetainedValue()) as String
            if uuid.caseInsensitiveCompare(value) == .orderedSame { return screen.localizedName }
        }
        return "Display \(fallback)"
    }

    func displayBounds(for uuid: String) -> CGRect? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let displayUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
            else { continue }
            let value = CFUUIDCreateString(nil, displayUUID.takeRetainedValue()) as String
            if uuid.caseInsensitiveCompare(value) == .orderedSame {
                return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            }
        }
        return nil
    }
}

/// Uses standard Mission Control shortcuts via System Events, NOT private writes.
/// Switching can take several steps and may require Automation permission.
final class SpaceSwitcher {
    private let queue = DispatchQueue(label: "com.hiro259.oniwa.switch", qos: .userInitiated)

    func switchTo(_ target: SpaceEntry, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result: Result<Void, Error> = self.performSwitch(target)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func performSwitch(_ target: SpaceEntry) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        guard let group = reader.displays().first(where: { $0.id == target.displayID }),
              let targetIndex = group.spaces.firstIndex(where: { $0.systemID == target.systemID })
        else { return .failure(SwitchFailure("That Space no longer exists. Reopen search.")) }

        // With separate Spaces per display, the arrow shortcut follows cursor focus.
        guard let frame = reader.displayBounds(for: target.displayID) else {
            return .failure(SwitchFailure("Cannot identify target display. No switch was attempted."))
        }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        Thread.sleep(forTimeInterval: 0.07)
        guard let current = reader.displays().first(where: { $0.id == target.displayID }),
              let currentIndex = current.spaces.firstIndex(where: { $0.isCurrent })
        else { return .failure(SwitchFailure("Cannot determine the current Space.")) }
        let delta = targetIndex - currentIndex
        if delta == 0 { return .success(()) }
        for _ in 0..<abs(delta) {
            let previous = reader.displays().first(where: { $0.id == target.displayID })?.currentID
            let keyCode = delta > 0 ? 124 : 123
            var error: NSDictionary?
            let script = NSAppleScript(source:
                "tell application \"System Events\" to key code \(keyCode) using control down")
            _ = script?.executeAndReturnError(&error)
            if let error {
                return .failure(SwitchFailure("System Events failed: \(error). Check Automation permission."))
            }
            var changed = false
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.06)
                let now = reader.displays().first(where: { $0.id == target.displayID })?.currentID
                if now != nil && now != previous { changed = true; break }
            }
            if !changed { return .failure(SwitchFailure("Space transition was not confirmed.")) }
        }
        let arrived = reader.displays().first(where: { $0.id == target.displayID })?.currentID
        return arrived == target.systemID
            ? .success(())
            : .failure(SwitchFailure("Switched, but did not reach the selected Space."))
    }

    private struct SwitchFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

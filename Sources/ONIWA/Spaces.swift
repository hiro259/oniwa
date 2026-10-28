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

    func displays(includeAppNames: Bool = true) -> [DisplayGroup] {
        guard let connectionFn, let layoutFn,
              let raw = layoutFn(connectionFn()) as? [[String: Any]] else { return [] }

        // Switching polls only Space IDs: querying every window on every poll
        // would add avoidable latency on a Mac with many open windows.
        let ownerNames = includeAppNames ? windowOwners(connection: connectionFn()) : [:]
        return raw.enumerated().compactMap { displayIndex, display in
            guard let displayID = display["Display Identifier"] as? String,
                  let spaceDicts = display["Spaces"] as? [[String: Any]] else { return nil }
            let name = displayName(displayID, fallback: displayIndex + 1)
            let currentDictionary = display["Current Space"] as? [String: Any]
            let current = (currentDictionary?["ManagedSpaceID"] as? NSNumber)
                ?? (currentDictionary?["id64"] as? NSNumber)
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
/// The private SkyLight API is strictly read-only. A jump stops rather than
/// continuing blindly if a Space disappears, gets reordered, or the observed
/// transition does not land on the expected immediate neighbor.
final class SpaceSwitcher {
    private let queue = DispatchQueue(label: "com.hiro259.oniwa.switch", qos: .userInitiated)
    private let pollInterval: TimeInterval = 0.06
    private let transitionTimeout: TimeInterval = 3.0

    func switchTo(_ target: SpaceEntry, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result: Result<Void, Error> = self.performSwitch(target)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func performSwitch(_ target: SpaceEntry) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        let initialDisplays = reader.displays(includeAppNames: false)
        guard let initial = initialDisplays.first(where: { $0.id == target.displayID }),
              initial.spaces.contains(where: { $0.systemID == target.systemID })
        else {
            return .failure(SwitchFailure(
                "選択したSpaceが見つかりません。検索パネルを更新してください。"))
        }

        let originalOrder = initial.spaces.map(\.systemID)
        guard let originalCurrentID = initial.currentID else {
            return .failure(SwitchFailure("現在表示中のSpaceを確認できません。"))
        }
        // No reason to manipulate the cursor when that desktop is already visible.
        if originalCurrentID == target.systemID { return .success(()) }

        guard let displayBounds = reader.displayBounds(for: target.displayID) else {
            return .failure(SwitchFailure(
                "移動先のモニターを識別できません。画面構成を確認してください。"))
        }

        // The built-in Ctrl+arrow Space shortcut acts on the display under the
        // pointer on Macs with "Displays have separate Spaces" enabled.
        // If the pointer is already on that display, do not needlessly warp it.
        let pointer = CGEvent(source: nil)?.location
        if pointer == nil || !displayBounds.contains(pointer!) {
            let error = CGWarpMouseCursorPosition(
                CGPoint(x: displayBounds.midX, y: displayBounds.midY))
            guard error == .success else {
                return .failure(SwitchFailure("対象モニターにカーソルを移せませんでした。"))
            }
            Thread.sleep(forTimeInterval: 0.07)
        }

        // Each successful step must land on precisely the neighboring Space.
        // Re-read both the ordering and the active Space before the next step.
        // We intentionally do not chase an arbitrary new position if the user
        // changes Spaces or the system rearranges the layout during navigation.
        for _ in 0..<originalOrder.count {
            guard let live = reader.displays(includeAppNames: false)
                .first(where: { $0.id == target.displayID }) else {
                return .failure(SwitchFailure("対象モニターが接続解除されました。"))
            }
            let order = live.spaces.map(\.systemID)
            guard order == originalOrder else {
                return .failure(SwitchFailure(
                    "移動中にSpaceの順序が変わりました。安全のため中断しました。"))
            }
            guard let current = live.currentID else {
                return .failure(SwitchFailure("現在のSpaceを確認できなくなりました。"))
            }
            let decision: SpaceNavigation.Decision
            do {
                decision = try SpaceNavigation.nextStep(
                    orderedSpaceIDs: order, current: current, target: target.systemID)
            } catch {
                return .failure(SwitchFailure(
                    "Spaceの識別情報が変化しました。検索を開き直してください。"))
            }

            switch decision {
            case .arrived:
                return .success(())
            case let .move(direction, nextSpaceID):
                let code = direction == .right ? 124 : 123
                var scriptError: NSDictionary?
                let script = NSAppleScript(source:
                    "tell application \"System Events\" to key code \(code) using control down")
                guard let script else {
                    return .failure(SwitchFailure("切り替え操作を作成できませんでした。"))
                }
                _ = script.executeAndReturnError(&scriptError)
                if let scriptError {
                    NSLog("ONIWA: System Events switch error: %@", scriptError)
                    return .failure(SwitchFailure(
                        "macOSの操作が許可されませんでした。「プライバシーとセキュリティ」→「オートメーション」でSystem Eventsの許可を確認してください。"))
                }

                switch waitForNeighbor(
                    previous: current, expected: nextSpaceID,
                    displayID: target.displayID, reader: reader
                ) {
                case .confirmed: break
                case .wrongSpace:
                    return .failure(SwitchFailure(
                        "予定とは異なるSpaceへ移動しました。これ以上の自動切り替えを停止しました。"))
                case .disconnected:
                    return .failure(SwitchFailure("切り替え中にモニターを認識できなくなりました。"))
                case .timedOut:
                    return .failure(SwitchFailure(
                        "Spaceの移動を確認できません。Mission Controlの「左/右の操作スペースに移動」ショートカットが有効か確認してください。"))
                }
            }
        }

        // If the system never acknowledged arrival, never report success.
        return .failure(SwitchFailure(
            "Spaceの切り替えを完了できませんでした。"))
    }

    private enum StepOutcome {
        case confirmed
        case wrongSpace
        case disconnected
        case timedOut
    }

    private func waitForNeighbor(previous: UInt64, expected: UInt64,
                                 displayID: String, reader: SpaceReader) -> StepOutcome {
        let deadline = Date().addingTimeInterval(transitionTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            guard let display = reader.displays(includeAppNames: false)
                .first(where: { $0.id == displayID }) else { return .disconnected }
            guard let now = display.currentID else { continue }
            if now == expected { return .confirmed }
            // One unexpected step may indicate a user action or shortcut conflict.
            if now != previous { return .wrongSpace }
        }
        return .timedOut
    }

    private struct SwitchFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

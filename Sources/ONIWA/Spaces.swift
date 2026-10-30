import AppKit
import CoreGraphics
import Foundation
import ONIWACore

struct SpaceEntry: Identifiable, Hashable {
    let identity: SpaceIdentity
    var id: String { identity.runtimeKey }
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
                // The numeric Space ID is used only while this Space exists.
                let identity = SpaceIdentity(displayID: displayID, managedID: id, uuid: uuid)
                let kind = (record["type"] as? NSNumber)?.intValue ?? 0
                return SpaceEntry(identity: identity, systemID: id, displayID: displayID,
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

/// Uses standard Mission Control shortcuts via Core Graphics, NOT private writes.
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

    /// The user requests two displays with a single action, but transitions
    /// run sequentially on the same queue and are checked separately.
    func switchToPair(_ pair: SpacePair, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = self.performPairSwitch(pair)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func performPairSwitch(_ pair: SpacePair) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        SpaceSwitchDiagnostics.record("pair start id=\(pair.id)")
        let before = reader.displays(includeAppNames: false)
        guard let resolved = SpacePairResolver.resolve(
            pair, in: before.flatMap(\.spaces).map(\.identity)),
              let first = before.flatMap(\.spaces).first(where: { $0.identity == resolved.0 })
        else {
            return .failure(SwitchFailure(
                "セット内のSpaceが見つかりません。別のSpaceに置き換えず、セットを編集してください。"))
        }

        // Snapshot unrelated displays so we can detect an unintended change.
        var untouched: [String: UInt64] = [:]
        for display in before
            where display.id != pair.first.displayID && display.id != pair.second.displayID {
            if let current = display.currentID { untouched[display.id] = current }
        }

        switch performSwitch(first) {
        case .failure(let error):
            return .failure(SwitchFailure(
                "セットの1つ目（\(first.displayName)）に切り替えられませんでした。"
                + "2つ目は操作していません。\(error.localizedDescription)"))
        case .success:
            break
        }

        // Always read a fresh layout. Do not reuse the second Space's numeric
        // ID blindly after the first monitor's transition.
        let middle = reader.displays(includeAppNames: false)
        guard let livePair = SpacePairResolver.resolve(
            pair, in: middle.flatMap(\.spaces).map(\.identity)),
              let secondDisplay = middle.first(where: { $0.id == pair.second.displayID }),
              let second = secondDisplay.spaces.first(where: { $0.identity == livePair.1 }),
              middle.first(where: { $0.id == pair.first.displayID })?.currentID
                == livePair.0.managedID
        else {
            return .failure(SwitchFailure(
                "1つ目のSpaceへの移動後に画面構成が変わりました。"
                + "2つ目は操作せず中断しました。"))
        }

        switch performSwitch(second) {
        case .failure(let error):
            return .failure(SwitchFailure(
                "1つ目（\(first.displayName)）は到達済みですが、"
                + "2つ目（\(second.displayName)）は切り替えに失敗しました。"
                + "自動的に元の状態には戻しません。\(error.localizedDescription)"))
        case .success:
            break
        }

        let after = reader.displays(includeAppNames: false)
        guard let finalPair = SpacePairResolver.resolve(
            pair, in: after.flatMap(\.spaces).map(\.identity)),
              after.first(where: { $0.id == pair.first.displayID })?.currentID
                == finalPair.0.managedID,
              after.first(where: { $0.id == pair.second.displayID })?.currentID
                == finalPair.1.managedID,
              untouched.allSatisfy({ id, oldSpace in
                  after.first(where: { $0.id == id })?.currentID == oldSpace
              })
        else {
            return .failure(SwitchFailure(
                "セット切り替え後に表示中のSpaceが想定と異なります。"
                + "他の画面も確認してください。追加操作は行いません。"))
        }
        return .success(())
    }

    private func performSwitch(_ target: SpaceEntry) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        let initialDisplays = reader.displays(includeAppNames: false)
        guard let initial = initialDisplays.first(where: { $0.id == target.displayID }),
              initial.spaces.contains(where: { $0.identity == target.identity })
        else {
            return .failure(SwitchFailure(
                "選択したSpaceが見つかりません。検索パネルを更新してください。"))
        }

        let originalOrder = initial.spaces.map(\.systemID)
        SpaceSwitchDiagnostics.record(
            "target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
            + "initial=\(initial.currentID.map(String.init) ?? "unknown") "
            + "expected=\(target.systemID) order=\(originalOrder)")
        guard let originalCurrentID = initial.currentID else {
            return .failure(SwitchFailure("現在表示中のSpaceを確認できません。"))
        }
        // No reason to manipulate the cursor when that desktop is already visible.
        if originalCurrentID == target.systemID { return .success(()) }

        guard let displayBounds = reader.displayBounds(for: target.displayID) else {
            return .failure(SwitchFailure(
                "移動先のモニターを識別できません。画面構成を確認してください。"))
        }

        // Warp by itself produces no mouse movement event. Inform Dock of the
        // new pointer display and verify it before a synthetic Space gesture.
        guard routePointer(to: displayBounds, displayID: target.displayID) else {
            return .failure(SwitchFailure(
                "対象モニターへのカーソル移動を確認できません。安全のため停止しました。"))
        }

        // Each successful step must land on precisely the neighboring Space.
        // Re-read both the ordering and the active Space before the next step.
        // We intentionally do not chase an arbitrary new position if the user
        // changes Spaces or the system rearranges the layout during navigation.
        for _ in 0..<originalOrder.count {
            let layout = reader.displays(includeAppNames: false)
            guard let live = layout.first(where: { $0.id == target.displayID }) else {
                return .failure(SwitchFailure("対象モニターが接続解除されました。"))
            }
            guard layout.allSatisfy({ $0.currentID != nil }) else {
                return .failure(SwitchFailure(
                    "一部モニターのSpace状態が不明なため、切り替えを中断しました。"))
            }
            var beforeOthers: [String: UInt64] = [:]
            for display in layout where display.id != target.displayID {
                if let id = display.currentID { beforeOthers[display.id] = id }
            }
            let order = live.spaces.map(\.systemID)
            guard live.spaces.contains(where: { $0.identity == target.identity }) else {
                return .failure(SwitchFailure(
                    "対象のSpaceの識別子が変わったため、安全のため中断しました。"))
            }
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
                SpaceSwitchDiagnostics.record(
                    "step target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
                    + "from=\(current) to=\(nextSpaceID) "
                    + "mode=\(InstantSwitchSettings.enabled ? "instant-first" : "keyboard")")
                guard let cursor = CGEvent(source: nil)?.location,
                      displayBounds.contains(cursor) else {
                    return .failure(SwitchFailure(
                        "切り替え中にカーソルが別モニターへ移動しました。中断しました。"))
                }
                // Post the standard Control+arrow Mission Control shortcut
                // directly through Core Graphics. This avoids sending Apple
                // Events to System Events, which can fail with error 1002 even
                // when the app has a working global shortcut.
                if !CGPreflightPostEventAccess() {
                    _ = CGRequestPostEventAccess()
                    return .failure(SwitchFailure(
                        "macOSがキー操作の送信を許可していません。アクセシビリティでONIWA（現在のビルド）を許可し、アプリを再起動してください。変更後も直らない場合は、署名とアプリの保存先を確認してください。"))
                }
                // ONIWA-only fast path: a near-zero Dock swipe using the
                // native Mission Control pipeline. We never trust event posting
                // as proof of a switch. If no movement is observed, verify the
                // live ID again before trying the existing Ctrl+arrow fallback.
                // Unexpected movement is a hard stop, never another keypress.
                if InstantSwitchSettings.enabled,
                   InstantSpaceGesture.post(right: direction == .right) {
                    switch waitForNeighbor(
                        previous: current, expected: nextSpaceID,
                        displayID: target.displayID, reader: reader,
                        timeout: 0.9
                    ) {
                    case .confirmed:
                        // The next loop verifies the next neighboring Space.
                        continue
                    case .wrongSpace:
                        return .failure(SwitchFailure(
                            "瞬時切り替えで別のSpaceに移動しました。安全のため自動切り替えを停止しました。"))
                    case .disconnected:
                        return .failure(SwitchFailure(
                            "瞬時切り替え中にモニターを認識できなくなりました。"))
                    case .timedOut:
                        // A delayed/unsupported synthetic gesture might still
                        // be in flight. Give the system an extra observation,
                        // and never emit Ctrl+arrow after movement was seen.
                        guard let latest = reader.displays(includeAppNames: false)
                            .first(where: { $0.id == target.displayID }) else {
                            return .failure(SwitchFailure(
                                "対象モニターが接続解除されました。"))
                        }
                        switch InstantSwitchPolicy.fallbackDecision(
                            previous: current, expected: nextSpaceID,
                            observed: latest.currentID,
                            orderUnchanged: latest.spaces.map(\.systemID) == originalOrder
                        ) {
                        case .alreadySwitched:
                            continue
                        case .keyboard:
                            break // The previous Space is still current.
                        case .abort:
                            return .failure(SwitchFailure(
                                "Spaceの移動状態または順序が変わったため、追加操作を中断しました。"))
                        }
                        // No movement after the fast gesture: normal fallback.
                    }
                }

                // On macOS 26/27, Mission Control can ignore a synthetic
                // Ctrl+Arrow sent with only .maskControl. Reproduce the
                // hardware keyboard event sequence instead:
                //   Ctrl down -> Arrow down/up (Control|Fn|NumericPad) -> Ctrl up.
                // Use a HID-system-state event source, not a session-level one.
                // See: AprilNEA/OpenLogi#1653 (verified on macOS 27.0.1).
                let arrowCode: CGKeyCode = direction == .right ? 124 : 123
                let controlCode: CGKeyCode = 59
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let controlDown = CGEvent(keyboardEventSource: source,
                                                virtualKey: controlCode, keyDown: true),
                      let arrowDown = CGEvent(keyboardEventSource: source,
                                              virtualKey: arrowCode, keyDown: true),
                      let arrowUp = CGEvent(keyboardEventSource: source,
                                            virtualKey: arrowCode, keyDown: false),
                      let controlUp = CGEvent(keyboardEventSource: source,
                                              virtualKey: controlCode, keyDown: false) else {
                    return .failure(SwitchFailure(
                        "Space切り替え用のHIDキーイベントを生成できませんでした。"))
                }

                let arrowFlags: CGEventFlags = [
                    .maskControl, .maskSecondaryFn, .maskNumericPad
                ]
                controlDown.flags = .maskControl
                arrowDown.flags = arrowFlags
                arrowUp.flags = arrowFlags
                controlUp.flags = []

                controlDown.post(tap: .cghidEventTap)
                arrowDown.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.012)
                arrowUp.post(tap: .cghidEventTap)
                controlUp.post(tap: .cghidEventTap)

                // CGEvent.post has no acknowledgement. The verified Space ID
                // transition below, not successful posting, determines success.

                switch waitForNeighbor(
                    previous: current, expected: nextSpaceID,
                    displayID: target.displayID, reader: reader,
                    timeout: transitionTimeout
                ) {
                case .confirmed: break
                case .wrongSpace:
                    return .failure(SwitchFailure(
                        "予定とは異なるSpaceへ移動しました。これ以上の自動切り替えを停止しました。"))
                case .disconnected:
                    return .failure(SwitchFailure("切り替え中にモニターを認識できなくなりました。"))
                case .timedOut:
                    return .failure(SwitchFailure(
                        "Spaceの移動を確認できません。物理キーボードの⌃+←/→で移動できるか確認してください。手動操作が成功する場合、ONIWAのキー送信またはモニター判定が原因の可能性があります。"))
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
                                 displayID: String, reader: SpaceReader,
                                 timeout: TimeInterval) -> StepOutcome {
        let deadline = Date().addingTimeInterval(timeout)
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

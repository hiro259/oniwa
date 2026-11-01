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
        let before = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record(
            "pair start id=\(pair.id) "
            + "first=\(SpaceSwitchDiagnostics.shortDisplay(pair.first.displayID)):"
            + "\(String(pair.first.uuid.prefix(8))) "
            + "second=\(SpaceSwitchDiagnostics.shortDisplay(pair.second.displayID)):"
            + "\(String(pair.second.uuid.prefix(8)))")
        SpaceSwitchDiagnostics.record("pair initial \(traceLayout(before))")
        guard let resolved = SpacePairResolver.resolve(
            pair, in: before.flatMap(\.spaces).map(\.identity)),
              let first = before.flatMap(\.spaces).first(where: { $0.identity == resolved.0 })
        else {
            return .failure(SwitchFailure(
                "セット内のSpaceが見つかりません。別のSpaceに置き換えず、セットを編集してください。"))
        }

        let numberedMode = SwitchModeSettings.desktopNumberExperimentMode
        if numberedMode != .off {
            return performNumberedPair(pair, before: before, mode: numberedMode)
        }
        let pairMode = SwitchModeSettings.pair
        let mcOneSessionExperiment =
            SwitchModeSettings.globalMCOneSessionExperimentEnabled
        if mcOneSessionExperiment {
            SpaceSwitchDiagnostics.record(
                "pair diagnostic-mc-one selected saved-pair=\(pairMode.rawValue)")
            return performPairSingleSession(pair, before: before)
        }
        let globalExperiment = SwitchModeSettings.globalInstantExperimentEnabled
        SpaceSwitchDiagnostics.record(
            "pair selected-mode=\(pairMode.rawValue) global-instant=\(globalExperiment)")
        if GlobalInstantExperimentPolicy.usesHybrid(
            enabled: globalExperiment, selected: pairMode) {
            return performPairHybrid(pair, before: before)
        }
        // Global experiment overrides both displays and every saved pair
        // strategy, but never overwrites those preferences.
        var pairHadGestureFallback = false
        let firstMode = GlobalInstantExperimentPolicy.pairStepMode(
            enabled: globalExperiment, selected: pairMode, hadGestureFallback: false)

        // Snapshot unrelated displays so we can detect an unintended change.
        var untouched: [String: UInt64] = [:]
        for display in before
            where display.id != pair.first.displayID && display.id != pair.second.displayID {
            if let current = display.currentID { untouched[display.id] = current }
        }

        switch performSwitch(
            first, preferredMode: firstMode, globalExperiment: globalExperiment,
            onInstantFallback: { pairHadGestureFallback = true }) {
        case .failure(let error):
            SpaceSwitchDiagnostics.record("pair first failed \(error.localizedDescription)")
            return .failure(SwitchFailure(
                "セットの1つ目（\(first.displayName)）に切り替えられませんでした。"
                + "2つ目は操作していません。\(error.localizedDescription)"))
        case .success:
            break
        }

        // Always read a fresh layout. Do not reuse the second Space's numeric
        // ID blindly after the first monitor's transition.
        let middle = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record("pair after-first \(traceLayout(middle))")
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

        if secondDisplay.currentID == second.systemID {
            SpaceSwitchDiagnostics.record(
                "pair second skipped: already current display="
                + "\(SpaceSwitchDiagnostics.shortDisplay(second.displayID))"
                + " space=\(second.systemID)"
                + " uuid=\(String(second.identity.uuid?.prefix(8) ?? "unknown"))")
        }
        let secondMode = GlobalInstantExperimentPolicy.pairStepMode(
            enabled: globalExperiment, selected: pairMode,
            hadGestureFallback: pairHadGestureFallback)
        SpaceSwitchDiagnostics.record(
            "pair second-mode=\(secondMode.rawValue)"
            + " prior-fallback=\(pairHadGestureFallback)")
        switch performSwitch(
            second, preferredMode: secondMode, globalExperiment: globalExperiment,
            onInstantFallback: { pairHadGestureFallback = true }) {
        case .failure(let error):
            SpaceSwitchDiagnostics.record("pair second failed \(error.localizedDescription)")
            return .failure(SwitchFailure(
                "1つ目（\(first.displayName)）は到達済みですが、"
                + "2つ目（\(second.displayName)）は切り替えに失敗しました。"
                + "自動的に元の状態には戻しません。\(error.localizedDescription)"))
        case .success:
            break
        }

        let after = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record("pair after-second \(traceLayout(after))")
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
        // A reported currentID can lead the visible desktop transition.
        // Observe the full layout again after the UI has had time to settle.
        // This does not prove app windows are visible, but detects delayed
        // reordering and delayed Space changes missed by the first sample.
        // Dock can re-activate an off-Space window around 400 ms after
        // a nominal arrival. A 350 ms sample can report false success.
        Thread.sleep(forTimeInterval: 0.85)
        let settled = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record("pair settled \(traceLayout(settled))")
        guard let stablePair = SpacePairResolver.resolve(
            pair, in: settled.flatMap(\.spaces).map(\.identity)),
              settled.first(where: { $0.id == pair.first.displayID })?.currentID
                == stablePair.0.managedID,
              settled.first(where: { $0.id == pair.second.displayID })?.currentID
                == stablePair.1.managedID,
              untouched.allSatisfy({ id, oldSpace in
                  settled.first(where: { $0.id == id })?.currentID == oldSpace
              })
        else {
            SpaceSwitchDiagnostics.record("pair delayed mismatch: after-second IDs did not stay stable")
            return .failure(SwitchFailure(
                "セット移動直後は目標Spaceでしたが、表示の安定待ち中に"
                + "別のSpaceへ変わりました。診断ログを確認してください。"))
        }
        SpaceSwitchDiagnostics.record("pair complete confirmed")
        return .success(())
    }

    /// Experimental mixed-mode pair switch. It MUST not depend on the
    /// ordering of SpacePair.first/second: resolve actual physical displays.
    /// When an internal display is unavailable (clamshell/external-only),
    /// fail safely instead of guessing where Ctrl+Arrow will be routed.
    private func performPairHybrid(
        _ pair: SpacePair, before: [DisplayGroup]
    ) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        guard before.allSatisfy({ $0.currentID != nil }) else {
            return .failure(SwitchFailure(
                "混合式：接続ディスプレイのSpace状態が不明なため中断しました。"))
        }
        // The same NSScreen->CGDisplay UUID mapping is used by the ordinary
        // SpaceReader for every monitor. Do not derive roles from pair order
        // or the first/second item of the live Space list.
        var physicalRoles: [String: Bool] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuidRef = CGDisplayCreateUUIDFromDisplayID(
                    CGDirectDisplayID(number.uint32Value)) else {
                SpaceSwitchDiagnostics.record("pair-hybrid abort: screen UUID unavailable")
                return .failure(SwitchFailure(
                    "混合式：物理ディスプレイの識別情報を取得できません。"))
            }
            let uuid = (CFUUIDCreateString(nil, uuidRef.takeRetainedValue()) as String)
                .lowercased()
            guard physicalRoles[uuid] == nil else {
                return .failure(SwitchFailure(
                    "混合式：ディスプレイの識別子が重複しています。"))
            }
            physicalRoles[uuid] = CGDisplayIsBuiltin(
                CGDirectDisplayID(number.uint32Value)) != 0
        }
        guard let route = PairHybridRouting.resolve(
            firstDisplayID: pair.first.displayID,
            secondDisplayID: pair.second.displayID,
            isBuiltInByDisplayID: physicalRoles),
              let resolved = SpacePairResolver.resolve(
                pair, in: before.flatMap(\.spaces).map(\.identity)),
              let builtIn = before.flatMap(\.spaces).first(where: {
                $0.displayID == route.builtInDisplayID
                    && ($0.identity == resolved.0 || $0.identity == resolved.1)
              }),
              let external = before.flatMap(\.spaces).first(where: {
                $0.displayID == route.externalDisplayID
                    && ($0.identity == resolved.0 || $0.identity == resolved.1)
              }),
              let beforeBuiltIn = before.first(where: { $0.id == builtIn.displayID }),
              let beforeExternal = before.first(where: { $0.id == external.displayID })
        else {
            SpaceSwitchDiagnostics.record("pair-hybrid abort: ambiguous physical roles or UUID")
            return .failure(SwitchFailure(
                "混合式は内蔵ディスプレイ1台＋拡張ディスプレイ1台のセットに対応しています。"
                + "現在のディスプレイ構成では安全に識別できません。"))
        }

        let untouched = currentSpaceIDs(before.filter {
            $0.id != builtIn.displayID && $0.id != external.displayID
        })
        SpaceSwitchDiagnostics.record(
            "pair-hybrid start mc=\(SpaceSwitchDiagnostics.shortDisplay(builtIn.displayID)):"
            + "\(builtIn.systemID) keyboard=\(SpaceSwitchDiagnostics.shortDisplay(external.displayID)):"
            + "\(external.systemID) initial=\(traceLayout(before))")

        if beforeBuiltIn.currentID != builtIn.systemID {
            // Do not send an unrelated shortcut if the direct MC action
            // fails, even when the other display was already correct.
            switch performSwitch(builtIn, preferredMode: .missionControl) {
            case .failure(let error):
                SpaceSwitchDiagnostics.record(
                    "pair-hybrid built-in failed: \(error.localizedDescription)")
                return .failure(SwitchFailure(
                    "混合式：内蔵ディスプレイのMission Control移動に失敗しました。"
                    + "拡張ディスプレイは操作していません。\(error.localizedDescription)"))
            case .success:
                break
            }
        } else {
            SpaceSwitchDiagnostics.record("pair-hybrid built-in skipped: already current")
        }

        let middle = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record("pair-hybrid after-mc \(traceLayout(middle))")
        guard let livePair = SpacePairResolver.resolve(
            pair, in: middle.flatMap(\.spaces).map(\.identity)),
              middle.first(where: { $0.id == builtIn.displayID })?.currentID
                == builtIn.systemID,
              middle.first(where: { $0.id == external.displayID })?.currentID
                == beforeExternal.currentID,
              untouched.allSatisfy({ id, expectedID in
                  middle.first(where: { $0.id == id })?.currentID == expectedID
              }),
              [livePair.0, livePair.1].contains(builtIn.identity),
              [livePair.0, livePair.1].contains(external.identity)
        else {
            return .failure(SwitchFailure(
                "混合式：内蔵ディスプレイの移動後にSpace構成か別画面の状態が変化しました。"
                + "拡張ディスプレイは操作せず中断しました。"))
        }

        if middle.first(where: { $0.id == external.displayID })?.currentID
            != external.systemID {
            // Mission Control must be closed before sending Ctrl+Arrow.
            // AXPress success alone does not prove its overlay is gone.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while MissionControlDirectSwitch.hasVisibleThumbnailLists(),
                  ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
            }
            guard !MissionControlDirectSwitch.hasVisibleThumbnailLists() else {
                SpaceSwitchDiagnostics.record("pair-hybrid abort: Mission Control still visible")
                return .failure(SwitchFailure(
                    "混合式：Mission Controlがまだ開いています。"
                    + "誤操作を避けるため拡張側のキー送信を中断しました。"))
            }
            // Forced keyboard path bypasses BOTH direct MC and the
            // potentially unstable fast Dock swipe, regardless of global
            // single-Space preferences.
            switch performSwitch(external, preferredMode: .keyboard) {
            case .failure(let error):
                SpaceSwitchDiagnostics.record(
                    "pair-hybrid external failed: \(error.localizedDescription)")
                return .failure(SwitchFailure(
                    "混合式：内蔵ディスプレイは移動済みですが、"
                    + "拡張ディスプレイのキーボード移動に失敗しました。"
                    + "自動ロールバックはしません。\(error.localizedDescription)"))
            case .success:
                break
            }
        } else {
            SpaceSwitchDiagnostics.record("pair-hybrid external skipped: already current")
        }

        // Final comparison covers both requested Spaces and every unrelated
        // display. A second sample >400ms detects delayed Space snap-backs.
        let arrived = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record("pair-hybrid after-keyboard \(traceLayout(arrived))")
        let startedAt = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.85)
        let settled = reader.displays(includeAppNames: false)
        SpaceSwitchDiagnostics.record(
            "pair-hybrid settled elapsedMs="
            + "\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) "
            + "\(traceLayout(settled))")
        for sample in [arrived, settled] {
            guard let verifiedPair = SpacePairResolver.resolve(
                pair, in: sample.flatMap(\.spaces).map(\.identity)),
                  sample.first(where: { $0.id == builtIn.displayID })?.currentID
                    == builtIn.systemID,
                  sample.first(where: { $0.id == external.displayID })?.currentID
                    == external.systemID,
                  [verifiedPair.0, verifiedPair.1].contains(builtIn.identity),
                  [verifiedPair.0, verifiedPair.1].contains(external.identity),
                  untouched.allSatisfy({ id, oldSpace in
                      sample.first(where: { $0.id == id })?.currentID == oldSpace
                  }) else {
                SpaceSwitchDiagnostics.record("pair-hybrid failed final verification")
                return .failure(SwitchFailure(
                    "混合式：切り替え後の2画面または他のモニターの状態が一致しません。"
                    + "追加操作せず中断しました。"))
            }
        }
        SpaceSwitchDiagnostics.record("pair-hybrid complete confirmed")
        return .success(())
    }

    /// The numeric shortcut is experimental and NOT a direct Space ID setter.
    /// It addresses only user Desktops 1...9 and requires the user's standard
    /// Control+digit Mission Control shortcut to already be enabled.
    private enum NumberedOutcome {
        case complete
        case missing([String])
        case unsafe(String)
    }

    /// Samples all monitors, including the post-switch 350-400ms snap-back
    /// window. Unrelated monitors and any intermediate *wrong* ID are unsafe.
    /// Only stable, unchanged IDs may receive a keyboard fallback.
    private func inspectNumberedTransition(
        baseline: [DisplayGroup],
        impacted: [String: UInt64],
        trial: Int64,
        label: String
    ) -> NumberedOutcome {
        let baselineIDs = currentSpaceIDs(baseline)
        let start = ProcessInfo.processInfo.systemUptime
        var samples: [[String: UInt64]] = []
        for delay in [0.15, 0.35, 0.60, 0.85, 1.20] {
            Thread.sleep(forTimeInterval: max(
                0, delay - (ProcessInfo.processInfo.systemUptime - start)))
            let current = SpaceReader.shared.displays(includeAppNames: false)
            let ids = currentSpaceIDs(current)
            let rosterStable = current.count == baseline.count
                && baseline.allSatisfy { prior in
                    current.first(where: { $0.id == prior.id })?
                        .spaces.map(\.identity) == prior.spaces.map(\.identity)
                }
            let validIDs = ids.count == baselineIDs.count
                && baselineIDs.allSatisfy { id, old in
                    guard let now = ids[id] else { return false }
                    if let target = impacted[id] {
                        return now == old || now == target
                    }
                    return now == old
                }
            SpaceSwitchDiagnostics.record(
                "desktop-number trial=\(trial) sample=\(label)"
                + " delayMs=\(Int(delay * 1000)) rosterStable=\(rosterStable)"
                + " validIDs=\(validIDs) \(traceLayout(current))")
            guard rosterStable && validIDs else {
                return .unsafe("unrelated-space-or-roster-changed")
            }
            samples.append(ids)
        }

        guard samples.count >= 2,
              let final = samples.last,
              samples[samples.count - 2] == final else {
            return .unsafe("not-stable-at-end")
        }

        // Never repair an apparent failure if it was first observed at its
        // destination and then reverted: macOS may still own the transition.
        for (id, target) in impacted {
            guard let old = baselineIDs[id],
                  let now = final[id] else { return .unsafe("missing-display") }
            if now == old && old != target
                && samples.dropLast().contains(where: { $0[id] == target }) {
                return .unsafe("snap-back-after-arrival")
            }
        }
        let missing = impacted.keys.filter { final[$0] != impacted[$0] }.sorted()
        SpaceSwitchDiagnostics.record(
            "desktop-number trial=\(trial) inspected=\(label)"
            + " missing=\(missing.map(SpaceSwitchDiagnostics.shortDisplay))")
        return missing.isEmpty ? .complete : .missing(missing)
    }

    /// No double posting: an incomplete numeric shortcut is repaired only
    /// after repeated, unchanged snapshots, and the keyboard route starts
    /// only from the exact old Space.
    private func repairNumberedTargets(
        _ missing: [String],
        baseline: [DisplayGroup],
        targets: [String: SpaceEntry],
        trial: Int64
    ) -> Result<Void, Error> {
        var expectedIDs = currentSpaceIDs(SpaceReader.shared.displays(includeAppNames: false))
        let originalIDs = currentSpaceIDs(baseline)
        for displayID in missing {
            let before = SpaceReader.shared.displays(includeAppNames: false)
            guard currentSpaceIDs(before) == expectedIDs,
                  before.count == baseline.count,
                  baseline.allSatisfy({ old in
                      before.first(where: { $0.id == old.id })?
                          .spaces.map(\.identity) == old.spaces.map(\.identity)
                  }),
                  expectedIDs[displayID] == originalIDs[displayID],
                  let target = targets[displayID] else {
                return .failure(SwitchFailure(
                    "番号指定後にSpaceが変化しました。追加のキーは送信しません。"))
            }
            SpaceSwitchDiagnostics.record(
                "desktop-number trial=\(trial) keyboard-fallback"
                + " display=\(SpaceSwitchDiagnostics.shortDisplay(displayID))"
                + " target=\(target.systemID)")
            switch performSwitch(target, preferredMode: .keyboard,
                                globalExperiment: false) {
            case .failure(let error):
                return .failure(SwitchFailure(
                    "番号指定後のキーボード補完に失敗しました。"
                    + error.localizedDescription))
            case .success:
                expectedIDs[displayID] = target.systemID
                SpaceSwitchDiagnostics.record(
                    "desktop-number trial=\(trial) keyboard-repaired"
                    + " display=\(SpaceSwitchDiagnostics.shortDisplay(displayID))")
            }
        }
        return .success(())
    }

    private func verifyNumberedFinal(
        baseline: [DisplayGroup],
        targets: [String: SpaceEntry],
        trial: Int64
    ) -> Result<Void, Error> {
        let first = SpaceReader.shared.displays(includeAppNames: false)
        Thread.sleep(forTimeInterval: 0.85)
        let last = SpaceReader.shared.displays(includeAppNames: false)
        let original = currentSpaceIDs(baseline)
        let firstIDs = currentSpaceIDs(first)
        let lastIDs = currentSpaceIDs(last)
        let valid = firstIDs == lastIDs
            && last.count == baseline.count
            && baseline.allSatisfy { old in
                last.first(where: { $0.id == old.id })?
                    .spaces.map(\.identity) == old.spaces.map(\.identity)
            }
            && original.allSatisfy { id, old in
                if let target = targets[id] {
                    return lastIDs[id] == target.systemID
                }
                return lastIDs[id] == old
            }
        SpaceSwitchDiagnostics.record(
            "desktop-number trial=\(trial) finalVerified=\(valid)"
            + " \(traceLayout(last))")
        guard valid else {
            return .failure(SwitchFailure(
                "番号指定後のSpace状態が一致しません。安全のため追加操作せず停止しました。"))
        }
        return .success(())
    }

    private func performNumberedPair(
        _ pair: SpacePair, before: [DisplayGroup],
        mode: DesktopNumberExperimentMode
    ) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        guard let identities = SpacePairResolver.resolve(
            pair, in: before.flatMap(\.spaces).map(\.identity)),
              let firstGroup = before.first(where: { $0.id == pair.first.displayID }),
              let secondGroup = before.first(where: { $0.id == pair.second.displayID }),
              let first = firstGroup.spaces.first(where: { $0.identity == identities.0 }),
              let second = secondGroup.spaces.first(where: { $0.identity == identities.1 }),
              first.displayID != second.displayID,
              before.allSatisfy({ $0.currentID != nil }) else {
            return .failure(SwitchFailure(
                "番号指定実験：セットの2画面を一意に特定できません。"))
        }
        SpaceSwitchDiagnostics.beginWorkspaceTrace()
        defer { SpaceSwitchDiagnostics.endWorkspaceTrace() }
        let trial = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        let targets: [String: SpaceEntry] = [
            first.displayID: first, second.displayID: second
        ]
        let baselineIDs = currentSpaceIDs(before)
        let pending = [first, second].filter {
            baselineIDs[$0.displayID] != $0.systemID
        }
        let preparations = pending.map { target -> (SpaceEntry, DesktopNumberShortcut.Preparation) in
            let group = target.displayID == first.displayID ? firstGroup : secondGroup
            return (target, DesktopNumberShortcut.prepare(target, in: group))
        }
        let isAllDirect = preparations.allSatisfy {
            if case .ready = $0.1 { return true }
            return false
        }
        // Rapid mode is meaningful only when both shortcuts are available.
        // An ineligible Space safely degrades to verified per-monitor mode.
        let rapid = mode == .rapid && isAllDirect && pending.count == 2
        SpaceSwitchDiagnostics.record(
            "desktop-number trial=\(trial) begin mode=\(mode.rawValue)"
            + " actual=\(rapid ? "rapid" : "sequential")"
            + " pending=\(pending.map { SpaceSwitchDiagnostics.shortDisplay($0.displayID) })"
            + " \(traceLayout(before))")

        if rapid {
            guard CGPreflightPostEventAccess() else {
                _ = CGRequestPostEventAccess()
                return .failure(SwitchFailure(
                    "番号指定キー送信が許可されていません。アクセシビリティ権限を確認してください。"))
            }
            for (idx, entry) in preparations.enumerated() {
                guard case .ready(let shortcut) = entry.1,
                      let bounds = reader.displayBounds(for: entry.0.displayID),
                      routePointer(to: bounds, displayID: entry.0.displayID) else {
                    return .failure(SwitchFailure(
                        "番号指定：画面を識別できず送信を停止しました。"))
                }
                // Before pressing the second shortcut, first may be old or
                // target; other displays must remain at baseline.
                let current = reader.displays(includeAppNames: false)
                let ids = currentSpaceIDs(current)
                let safe = current.count == before.count
                    && before.allSatisfy { old in
                        current.first(where: { $0.id == old.id })?
                            .spaces.map(\.identity) == old.spaces.map(\.identity)
                    }
                    && baselineIDs.allSatisfy { id, initial in
                        let permitted = idx > 0 && id == first.displayID
                            ? [initial, first.systemID] : [initial]
                        return ids[id].map { permitted.contains($0) } ?? false
                    }
                guard safe else {
                    return .failure(SwitchFailure(
                        "番号指定の高速連続送信中に想定外のSpace移動を検出しました。"))
                }
                let sentAt = Int64(ProcessInfo.processInfo.systemUptime * 1000)
                guard DesktopNumberShortcut.post(shortcut) else {
                    return .failure(SwitchFailure(
                        "番号指定キー送信に失敗しました。追加操作を停止します。"))
                }
                SpaceSwitchDiagnostics.record(
                    "desktop-number trial=\(trial) posted-rapid"
                    + " order=\(idx + 1) display=\(SpaceSwitchDiagnostics.shortDisplay(entry.0.displayID))"
                    + " desktop=\(shortcut.number) uptimeMs=\(sentAt)")
            }
            let impacted = Dictionary(uniqueKeysWithValues:
                pending.map { ($0.displayID, $0.systemID) })
            let observed = inspectNumberedTransition(
                baseline: before, impacted: impacted, trial: trial,
                label: "rapid")
            switch observed {
            case .complete:
                SpaceSwitchDiagnostics.record(
                    "desktop-number trial=\(trial) result=direct-both rapid=true")
            case .missing(let ids):
                SpaceSwitchDiagnostics.record(
                    "desktop-number trial=\(trial) rapid-missed=\(ids)")
                switch repairNumberedTargets(ids, baseline: before,
                                             targets: targets, trial: trial) {
                case .success: break
                case .failure(let error): return .failure(error)
                }
            case .unsafe(let reason):
                SpaceSwitchDiagnostics.record(
                    "desktop-number trial=\(trial) result=unsafe-abort reason=\(reason)")
                return .failure(SwitchFailure(
                    "番号指定の高速連続送信後に状態が不安定です（\(reason)）。"
                    + "追加のキー操作は行いません。"))
            }
        } else {
            for (target, preparation) in preparations {
                let groupBaseline = reader.displays(includeAppNames: false)
                let startIDs = currentSpaceIDs(groupBaseline)
                guard groupBaseline.count == before.count,
                      before.allSatisfy({ old in
                          groupBaseline.first(where: { $0.id == old.id })?
                              .spaces.map(\.identity) == old.spaces.map(\.identity)
                      }),
                      targets.allSatisfy({ id, entry in
                          let expected = id == target.displayID
                              ? baselineIDs[id] : (startIDs[id] ?? 0)
                          return startIDs[id] == expected
                              || startIDs[id] == entry.systemID
                      }) else {
                    return .failure(SwitchFailure(
                        "番号指定の逐次移動前にSpace構成が変化しました。"))
                }
                switch preparation {
                case .fallback(let reason):
                    SpaceSwitchDiagnostics.record(
                        "desktop-number trial=\(trial) skipped-numeric"
                        + " display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
                        + " reason=\(reason) fallback=keyboard")
                    switch performSwitch(target, preferredMode: .keyboard,
                                        globalExperiment: false) {
                    case .success: break
                    case .failure(let error): return .failure(error)
                    }
                case .ready(let shortcut):
                    guard let bounds = reader.displayBounds(for: target.displayID),
                          routePointer(to: bounds, displayID: target.displayID),
                          DesktopNumberShortcut.post(shortcut) else {
                        return .failure(SwitchFailure(
                            "番号指定キーを対象画面へ送信できませんでした。"))
                    }
                    SpaceSwitchDiagnostics.record(
                        "desktop-number trial=\(trial) posted-sequential"
                        + " display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
                        + " desktop=\(shortcut.number)")
                    let inspected = inspectNumberedTransition(
                        baseline: groupBaseline,
                        impacted: [target.displayID: target.systemID],
                        trial: trial, label: "sequential")
                    switch inspected {
                    case .complete:
                        SpaceSwitchDiagnostics.record(
                            "desktop-number trial=\(trial) direct-confirmed"
                            + " display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))")
                    case .missing(let ids):
                        switch repairNumberedTargets(ids, baseline: groupBaseline,
                                                     targets: targets, trial: trial) {
                        case .success: break
                        case .failure(let error): return .failure(error)
                        }
                    case .unsafe(let reason):
                        SpaceSwitchDiagnostics.record(
                            "desktop-number trial=\(trial) result=unsafe-abort reason=\(reason)")
                        return .failure(SwitchFailure(
                            "番号指定の逐次移動後に状態が不安定です（\(reason)）。"
                            + "追加操作は行いません。"))
                    }
                }
            }
        }
        switch verifyNumberedFinal(baseline: before, targets: targets, trial: trial) {
        case .success:
            SpaceSwitchDiagnostics.record(
                "desktop-number trial=\(trial) result=pair-complete"
                + " mode=\(mode.rawValue) actual=\(rapid ? "rapid" : "sequential")")
            return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    private func performNumberedSingle(
        _ target: SpaceEntry, before: [DisplayGroup],
        shortcut: DesktopNumberShortcut.Ready
    ) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        let trial = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        SpaceSwitchDiagnostics.beginWorkspaceTrace()
        defer { SpaceSwitchDiagnostics.endWorkspaceTrace() }
        guard let bounds = reader.displayBounds(for: target.displayID),
              routePointer(to: bounds, displayID: target.displayID),
              DesktopNumberShortcut.post(shortcut) else {
            return .failure(SwitchFailure(
                "単独Spaceの番号指定キーを送信できませんでした。"))
        }
        SpaceSwitchDiagnostics.record(
            "desktop-number trial=\(trial) single-posted"
            + " display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
            + " desktop=\(shortcut.number)")
        switch inspectNumberedTransition(
            baseline: before, impacted: [target.displayID: target.systemID],
            trial: trial, label: "single"
        ) {
        case .complete:
            return verifyNumberedFinal(
                baseline: before, targets: [target.displayID: target], trial: trial)
        case .missing(let ids):
            switch repairNumberedTargets(ids, baseline: before,
                                         targets: [target.displayID: target],
                                         trial: trial) {
            case .failure(let error): return .failure(error)
            case .success:
                return verifyNumberedFinal(
                    baseline: before, targets: [target.displayID: target], trial: trial)
            }
        case .unsafe(let reason):
            return .failure(SwitchFailure(
                "単独Space番号指定の結果が不安定です（\(reason)）。追加操作しません。"))
        }
    }

    /// Diagnostic experiment: select both MC thumbnails from ONE session.
    /// Only a proven, unchanged Space can be repaired with keyboard input.
    /// On ambiguity or an overlay still present, do not send ANY keys.
    private func performPairSingleSession(
        _ pair: SpacePair, before: [DisplayGroup]
    ) -> Result<Void, Error> {
        let reader = SpaceReader.shared
        guard let resolved = SpacePairResolver.resolve(
            pair, in: before.flatMap(\.spaces).map(\.identity)),
              let firstDisplay = before.first(where: { $0.id == pair.first.displayID }),
              let secondDisplay = before.first(where: { $0.id == pair.second.displayID }),
              let first = firstDisplay.spaces.first(where: { $0.identity == resolved.0 }),
              let second = secondDisplay.spaces.first(where: { $0.identity == resolved.1 }),
              first.displayID != second.displayID,
              before.allSatisfy({ $0.currentID != nil }) else {
            return .failure(SwitchFailure(
                "MC一回実験：2画面のSpaceを一意に確認できません。"))
        }

        SpaceSwitchDiagnostics.beginWorkspaceTrace()
        defer { SpaceSwitchDiagnostics.endWorkspaceTrace() }
        let trial = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        let initialIDs = currentSpaceIDs(before)
        let targets: [String: UInt64] = [
            first.displayID: first.systemID,
            second.displayID: second.systemID
        ]
        let reverse = SwitchModeSettings.mcReversePressOrder
        let needsFirst = firstDisplay.currentID != first.systemID
        let needsSecond = secondDisplay.currentID != second.systemID
        let pattern = needsFirst && needsSecond ? "both-needed"
            : (needsFirst ? "first-only" : (needsSecond ? "second-only" : "both-current"))
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic trial=\(trial) begin pattern=\(pattern)"
            + " reverse=\(reverse) first=\(SpaceSwitchDiagnostics.shortDisplay(first.displayID))"
            + " second=\(SpaceSwitchDiagnostics.shortDisplay(second.displayID))"
            + " initial=\(traceLayout(before))")
        if !needsFirst && !needsSecond {
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) result=already-current")
            return .success(())
        }

        // A failed AXPress is not proof that neither display moved.
        // Inspect both after closing, even if the AX API returned an error.
        let pressed = MissionControlDirectSwitch.pressPairInOneSession(
            first: first, second: second, reader: reader, original: before,
            reverseOrder: reverse)
        switch pressed {
        case .success:
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) ax-result=sent")
        case .failure(let error):
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) ax-result=error"
                + " detail=\(SpaceSwitchDiagnostics.safe(error.localizedDescription))")
        }

        // Do not send Ctrl+arrows while the MC overlay is still active. On
        // macOS 27, a successful AXPress may precede overlay teardown.
        let deadline = ProcessInfo.processInfo.systemUptime + 3.0
        var closed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !MissionControlDirectSwitch.hasVisibleThumbnailLists() {
                closed = true
                break
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic trial=\(trial) overlay-closed=\(closed)")
        guard closed else {
            return .failure(SwitchFailure(
                "MC一回実験：Mission Controlが閉じていません。"
                + "キーボード移動は行いません。"))
        }

        // Sample late enough to catch the previously observed 350-400ms
        // reversal. Never use a provisional SkyLight ID as a fallback trigger.
        let started = ProcessInfo.processInfo.systemUptime
        var snapshots: [[DisplayGroup]] = []
        var allStable = true
        for sample in [0.15, 0.35, 0.60, 0.85, 1.20] {
            Thread.sleep(forTimeInterval: max(
                0, sample - (ProcessInfo.processInfo.systemUptime - started)))
            let layout = reader.displays(includeAppNames: false)
            snapshots.append(layout)
            let identitiesUnchanged = layout.count == before.count
                && before.allSatisfy { original in
                    layout.first(where: { $0.id == original.id })?
                        .spaces.map(\.identity) == original.spaces.map(\.identity)
                }
            let overlayGone = !MissionControlDirectSwitch.hasVisibleThumbnailLists()
            allStable = allStable && identitiesUnchanged && overlayGone
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) settle-ms=\(Int(sample * 1000))"
                + " identitiesStable=\(identitiesUnchanged)"
                + " overlayClosed=\(overlayGone) \(traceLayout(layout))")
        }
        guard snapshots.count >= 2 else {
            return .failure(SwitchFailure("MC一回実験：診断サンプル不足です。"))
        }
        let previous = currentSpaceIDs(snapshots[snapshots.count - 2])
        let latest = currentSpaceIDs(snapshots[snapshots.count - 1])
        // If a target was reached and then snapped back to its initial
        // Space, the two final samples alone could look like "unmoved".
        // That is NOT safe grounds for another keyboard movement.
        let reversedAfterArrival = [first, second].contains { target in
            guard initialIDs[target.displayID] != target.systemID,
                  latest[target.displayID] == initialIDs[target.displayID] else {
                return false
            }
            return snapshots.dropLast(2).contains { snapshot in
                currentSpaceIDs(snapshot)[target.displayID] == target.systemID
            }
        }
        let unexpectedIntermediateID = snapshots.contains { snapshot in
            let ids = currentSpaceIDs(snapshot)
            return before.contains { old in
                guard let actual = ids[old.id],
                      let initial = initialIDs[old.id] else { return true }
                if let expected = targets[old.id] {
                    return actual != initial && actual != expected
                }
                return actual != initial
            }
        }
        allStable = allStable && !reversedAfterArrival && !unexpectedIntermediateID
        let decision = MissionControlPairExperimentPolicy.decide(
            firstDisplay: first.displayID, secondDisplay: second.displayID,
            before: initialIDs, targets: targets,
            firstSample: previous, secondSample: latest,
            rosterStable: allStable, missionControlClosed: closed)
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic trial=\(trial) decision=\(decision)"
            + " sampledPrevious=\(previous) sampledLatest=\(latest)")
        let toRepair: [String]
        switch decision {
        case .complete:
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) result=mc-both-success"
                + " pattern=\(pattern) reverse=\(reverse)")
            return .success(())
        case .keyboard(let displays):
            toRepair = displays
        case .abort:
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) result=unsafe-abort")
            return .failure(SwitchFailure(
                "MC一回実験：Spaceの変化またはディスプレイ状態が不安定です。"
                + "誤移動防止のためキーボード移動は行いません。"))
        }

        // Recheck immediately before every keyboard operation. When a
        // preceding fallback changes one display, update the expected map.
        // If any other display changes spontaneously, stop rather than
        // interpreting a delayed MC transition as a missed click.
        var expectedIDs = latest
        for displayID in toRepair {
            let current = reader.displays(includeAppNames: false)
            guard !MissionControlDirectSwitch.hasVisibleThumbnailLists(),
                  current.count == before.count,
                  before.allSatisfy({ original in
                      current.first(where: { $0.id == original.id })?
                          .spaces.map(\.identity) == original.spaces.map(\.identity)
                  }),
                  currentSpaceIDs(current) == expectedIDs,
                  current.first(where: { $0.id == displayID })?.currentID
                    == initialIDs[displayID] else {
                SpaceSwitchDiagnostics.record(
                    "mc-pair-diagnostic trial=\(trial) fallback-abort"
                    + " display=\(SpaceSwitchDiagnostics.shortDisplay(displayID))")
                return .failure(SwitchFailure(
                    "MC一回実験：キーボード移動直前にSpace状態が変化しました。中断します。"))
            }
            let target = displayID == first.displayID ? first : second
            SpaceSwitchDiagnostics.record(
                "mc-pair-diagnostic trial=\(trial) keyboard-fallback"
                + " display=\(SpaceSwitchDiagnostics.shortDisplay(displayID))"
                + " target=\(target.systemID)")
            // A *forced* keyboard route. Neither global experiment is used,
            // and this fallback never changes any persisted menu selection.
            switch performSwitch(target, preferredMode: .keyboard,
                                globalExperiment: false) {
            case .success:
                expectedIDs[displayID] = target.systemID
                SpaceSwitchDiagnostics.record(
                    "mc-pair-diagnostic trial=\(trial) keyboard-confirmed"
                    + " display=\(SpaceSwitchDiagnostics.shortDisplay(displayID))")
            case .failure(let error):
                return .failure(SwitchFailure(
                    "MC一回実験：未到達の画面をキーボードで補完できませんでした。"
                    + error.localizedDescription))
            }
        }

        // Require a second stable final snapshot, including every unrelated
        // monitor, after the last keyboard correction.
        let finalNow = reader.displays(includeAppNames: false)
        Thread.sleep(forTimeInterval: 0.85)
        let finalLater = reader.displays(includeAppNames: false)
        let finalIDs = currentSpaceIDs(finalLater)
        let fullyArrived = currentSpaceIDs(finalNow) == finalIDs
            && finalLater.count == before.count
            && before.allSatisfy { original in
                finalLater.first(where: { $0.id == original.id })?
                    .spaces.map(\.identity) == original.spaces.map(\.identity)
            }
            && first.displayID != second.displayID
            && finalIDs[first.displayID] == first.systemID
            && finalIDs[second.displayID] == second.systemID
            && initialIDs.allSatisfy { id, old in
                targets[id] != nil || finalIDs[id] == old
            }
            && !MissionControlDirectSwitch.hasVisibleThumbnailLists()
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic trial=\(trial) finalVerified=\(fullyArrived)"
            + " fallbackCount=\(toRepair.count)"
            + " \(traceLayout(finalLater))")
        guard fullyArrived else {
            return .failure(SwitchFailure(
                "MC一回実験：補完後の2画面の状態が一致しません。追加操作しません。"))
        }
        SpaceSwitchDiagnostics.record(
            "mc-pair-diagnostic trial=\(trial) result=keyboard-repaired"
            + " count=\(toRepair.count) pattern=\(pattern) reverse=\(reverse)")
        return .success(())
    }

    private func traceLayout(_ groups: [DisplayGroup]) -> String {
        groups.map { display in
            let current = display.currentID.map(String.init) ?? "unknown"
            let uuid = display.spaces.first(where: { $0.systemID == display.currentID })?
                .identity.uuid.map { String($0.prefix(8)) } ?? "unknown"
            let order = display.spaces.map(\.systemID)
            return "\(SpaceSwitchDiagnostics.shortDisplay(display.id)){current:"
                + "\(current),uuid:\(uuid),order:\(order)}"
        }.joined(separator: " ")
    }

    private func performSwitch(
        _ target: SpaceEntry,
        preferredMode: SingleSpaceSwitchMode? = nil,
        globalExperiment: Bool? = nil,
        onInstantFallback: (() -> Void)? = nil
    ) -> Result<Void, Error> {
        let experiment = globalExperiment
            ?? SwitchModeSettings.globalInstantExperimentEnabled
        let mode = preferredMode
            ?? (SwitchModeSettings.globalMCOneSessionExperimentEnabled
                ? .missionControl
                : GlobalInstantExperimentPolicy.singleMode(
                    enabled: experiment, selected: SwitchModeSettings.single))
        var activeMode = mode
        func markInstantFallback(_ reason: String) {
            guard activeMode == .instant else { return }
            activeMode = .keyboard
            onInstantFallback?()
            SpaceSwitchDiagnostics.record(
                "instant-fallback keyboard reason=\(reason)"
                + " display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
                + " global=\(experiment)")
        }
        SpaceSwitchDiagnostics.record(
            "single selected-mode=\(mode.rawValue) global-instant=\(experiment)"
            + " target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))")
        let reader = SpaceReader.shared
        let initialDisplays = reader.displays(includeAppNames: false)
        guard let initial = initialDisplays.first(where: { $0.id == target.displayID }),
              initial.spaces.contains(where: { $0.identity == target.identity })
        else {
            return .failure(SwitchFailure(
                "選択したSpaceが見つかりません。検索パネルを更新してください。"))
        }

        let originalOrder = initial.spaces.map(\.systemID)
        guard SpaceNavigation.layoutChange(from: originalOrder,
                                           to: originalOrder) == .unchanged else {
            return .failure(SwitchFailure("Space IDが重複しているため安全に切り替えられません。"))
        }
        // Keep a fixed identity roster; ONLY order changes may be followed.
        // A recreated/reassigned Space or a changed monitor still aborts.
        let initialSpaces = initial.spaces
        var lastObservedOrder = originalOrder
        var visitedLayouts = Set<String>()
        let maxSteps = originalOrder.count * 2 + 2
        SpaceSwitchDiagnostics.record(
            "target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
            + "initial=\(initial.currentID.map(String.init) ?? "unknown") "
            + "expected=\(target.systemID) order=\(originalOrder)")
        guard let originalCurrentID = initial.currentID else {
            return .failure(SwitchFailure("現在表示中のSpaceを確認できません。"))
        }
        // Trace notifications through the entire switch and a short tail
        // afterwards, without changing the navigation or 450ms probe.
        SpaceSwitchDiagnostics.beginWorkspaceTrace()
        defer { SpaceSwitchDiagnostics.endWorkspaceTrace() }

        // No reason to manipulate the cursor when that desktop is already visible.
        if originalCurrentID == target.systemID {
            // A previously visible Space can still contain an app different
            // from the name inferred by ONIWA; capture that association too.
            traceSpaceMapping(target, reader: reader)
            return .success(())
        }

        if mode == .missionControl {
            // To detect a real unintended switch, every other monitor needs a
            // known baseline before Mission Control is opened. The overlay may
            // temporarily report other IDs, but only the settled IDs are final.
            let previousOthers = initialDisplays.filter { $0.id != target.displayID }
            guard previousOthers.allSatisfy({ $0.currentID != nil }) else {
                return .failure(SwitchFailure(
                    "別モニターの現在のSpaceを確認できないため、切り替えを中断しました。"))
            }
            let expectedOtherIDs = currentSpaceIDs(previousOthers)
            SpaceSwitchDiagnostics.record(
                "mc-direct selected target=\(target.systemID)"
                + " display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))")
            switch MissionControlDirectSwitch.press(
                target: target, reader: reader, original: initialDisplays) {
            case .failure(let error):
                return .failure(error)
            case .success:
                // AXPress acknowledges the button action, not Space arrival.
                // macOS 27 may need over 850ms before the first ID change.
                // Detect arrival independently, then verify the settled result.
                switch waitForDirectArrival(target, reader: reader,
                                            initial: initialDisplays) {
                case .failure(let error):
                    return .failure(error)
                case .success:
                    break
                }
                switch verifySettledTarget(target, reader: reader) {
                case .failure(let error):
                    return .failure(error)
                case .success:
                    let after = reader.displays(includeAppNames: false)
                    // Mission Control temporarily exposes its overlay Space IDs
                    // on other displays. Never fail just for an *intermediate*
                    // change; after the target's 850ms settle, however, every
                    // display must match its original Space exactly.
                    let afterIDs = currentSpaceIDs(after)
                    let outcome = MissionControlDirectObservation.settled(
                        targetDisplay: target.displayID,
                        expectedTarget: target.systemID,
                        beforeOthers: expectedOtherIDs,
                        after: afterIDs)
                    switch outcome {
                    case .confirmed:
                        SpaceSwitchDiagnostics.record(
                            "mc-direct confirmed target=\(target.systemID)"
                            + " all-displays-settled")
                        return .success(())
                    case .otherDisplayChanged, .displayUnavailable, .wrongTarget:
                        SpaceSwitchDiagnostics.record(
                            "mc-direct FAILED: post-settle outcome=\(outcome)"
                            + " initial=\(traceLayout(initialDisplays))"
                            + " actual=\(traceLayout(after))")
                        return .failure(SwitchFailure(
                            "Mission Control直接移動の完了後も別モニターまたは"
                            + "対象Spaceの状態が一致しません。"
                            + "安全のため追加操作は行いません。"))
                    }
                }
            }
        }

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

        // Each successful step must reach the immediate neighbor. After that,
        // reread the live layout. macOS may reorder the SAME Spaces between
        // two confirmed steps: replan on that new order rather than aborting.
        // Never follow an added/deleted/recreated Space or an unrelated display.
        for stepIndex in 0..<maxSteps {
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
            switch SpaceNavigation.layoutChange(from: originalOrder, to: order) {
            case .membershipChanged:
                SpaceSwitchDiagnostics.record(
                    "layout-membership-changed target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
                    + " original=\(originalOrder) now=\(order)")
                return .failure(SwitchFailure(
                    "移動中にSpaceが追加・削除・再作成されました。安全のため中断しました。"))
            case .unchanged, .reordered:
                // Even with the same numeric IDs, confirm UUID/display
                // identity for EVERY Space before accepting a reordering.
                let sameIdentities = live.spaces.allSatisfy { space in
                    initialSpaces.contains(where: { $0.identity == space.identity })
                }
                guard sameIdentities else {
                    SpaceSwitchDiagnostics.record(
                        "layout-identity-changed target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))")
                    return .failure(SwitchFailure(
                        "移動中にSpace UUIDが変化しました。安全のため中断しました。"))
                }
                if order != lastObservedOrder {
                    SpaceSwitchDiagnostics.record(
                        "order-replanned target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
                        + " step=\(stepIndex) old=\(lastObservedOrder) now=\(order)")
                    lastObservedOrder = order
                }
            }
            guard let current = live.currentID else {
                return .failure(SwitchFailure("現在のSpaceを確認できなくなりました。"))
            }
            let stateKey = "\(current)|\(order.map(String.init).joined(separator: ","))"
            guard visitedLayouts.insert(stateKey).inserted else {
                SpaceSwitchDiagnostics.record("repeated-state target=\(target.systemID) state=\(stateKey)")
                return .failure(SwitchFailure(
                    "Spaceの並び替えが繰り返されたため、誤移動を防ぐため停止しました。"))
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
                return verifySettledTarget(
                    target, reader: reader,
                    useInstant: activeMode == .instant)
            case let .move(direction, nextSpaceID):
                SpaceSwitchDiagnostics.record(
                    "step target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
                    + "from=\(current) to=\(nextSpaceID) "
                    + "direction=\(direction == .right ? "right" : "left") "
                    + "mode=\(activeMode == .instant ? "instant-first" : "keyboard")")
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
                let instantPosted = activeMode == .instant
                    ? InstantSpaceGesture.post(right: direction == .right)
                    : false
                if activeMode == .instant && instantPosted {
                    switch waitForNeighbor(
                        previous: current, expected: nextSpaceID,
                        displayID: target.displayID, reader: reader,
                        beforeOthers: beforeOthers, timeout: 0.9
                    ) {
                    case .confirmed:
                        // Optional A/B experiment: wait beyond the observed
                        // 150-350ms delayed Space snap-back before posting
                        // another gesture. This is NOT a permanent fast-mode
                        // speed change; the menu toggle defaults to OFF.
                        if experiment || InstantSwitchSettings.pacingProbeEnabled {
                            let startedAt = ProcessInfo.processInfo.systemUptime
                            Thread.sleep(forTimeInterval: 0.45)
                            let after = reader.displays(includeAppNames: false)
                            let outcome = SpaceSwitchObservation.evaluate(
                                targetDisplay: target.displayID,
                                beforeTarget: current,
                                expectedTarget: nextSpaceID,
                                beforeOthers: beforeOthers,
                                after: currentSpaceIDs(after))
                            let actual = after.first(where: { $0.id == target.displayID })?.currentID
                            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                            SpaceSwitchDiagnostics.record(
                                "instant-paced-settle t=\(elapsedMS)ms "
                                + "display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
                                + "expected=\(nextSpaceID) actual=\(actual.map(String.init) ?? "missing") "
                                + "outcome=\(outcome)")
                            guard outcome == .confirmed else {
                                return .failure(SwitchFailure(
                                    "瞬時切り替え後450ms以内にSpaceが再移動しました。"
                                    + "別のキーを送らず安全停止しました。"))
                            }
                        }
                        // The next loop verifies the next neighboring Space.
                        continue
                    case .wrongSpace:
                        return .failure(SwitchFailure(
                            "瞬時切り替えで別のSpaceに移動しました。安全のため自動切り替えを停止しました。"))
                    case .wrongDisplay:
                        return .failure(SwitchFailure(
                            "瞬時切り替えが別モニターに作用しました。追加操作を停止しました。診断ログを確認してください。"))
                    case .disconnected:
                        return .failure(SwitchFailure(
                            "瞬時切り替え中にモニターを認識できなくなりました。"))
                    case .timedOut:
                        // The Dock can report its state late. Observe twice,
                        // separated by 650ms, before posting ANY keyboard
                        // fallback. A confirmed late arrival, a snap-back,
                        // a changed display, or an altered roster must NEVER
                        // result in a second movement.
                        let sample1 = reader.displays(includeAppNames: false)
                        Thread.sleep(forTimeInterval: 0.65)
                        let sample2 = reader.displays(includeAppNames: false)
                        let firstLive = sample1.first(where: {
                            $0.id == target.displayID
                        })
                        let secondLive = sample2.first(where: {
                            $0.id == target.displayID
                        })
                        let firstOutcome = SpaceSwitchObservation.evaluate(
                            targetDisplay: target.displayID,
                            beforeTarget: current, expectedTarget: nextSpaceID,
                            beforeOthers: beforeOthers,
                            after: currentSpaceIDs(sample1))
                        let secondOutcome = SpaceSwitchObservation.evaluate(
                            targetDisplay: target.displayID,
                            beforeTarget: current, expectedTarget: nextSpaceID,
                            beforeOthers: beforeOthers,
                            after: currentSpaceIDs(sample2))
                        let rosterStable = [firstLive, secondLive].allSatisfy {
                            guard let live = $0,
                                  live.spaces.count == initialSpaces.count else {
                                return false
                            }
                            return live.spaces.allSatisfy { space in
                                initialSpaces.contains(where: {
                                    $0.identity == space.identity
                                })
                            }
                        }
                        let othersStable = [sample1, sample2].allSatisfy { snapshot in
                            beforeOthers.allSatisfy { id, oldID in
                                snapshot.first(where: { $0.id == id })?.currentID
                                    == oldID
                            }
                        }
                        let decision = InstantSwitchPolicy.settledFallbackDecision(
                            previous: current, expected: nextSpaceID,
                            firstObserved: firstLive?.currentID,
                            secondObserved: secondLive?.currentID,
                            firstOrderUnchanged: firstLive?.spaces.map(\.systemID) == order,
                            secondOrderUnchanged: secondLive?.spaces.map(\.systemID) == order,
                            otherDisplaysUnchanged: othersStable && rosterStable
                                && (firstOutcome == .waiting || firstOutcome == .confirmed)
                                && (secondOutcome == .waiting || secondOutcome == .confirmed)
                        )
                        SpaceSwitchDiagnostics.record(
                            "instant-timeout settle first=\(firstLive?.currentID.map(String.init) ?? "missing")"
                            + " second=\(secondLive?.currentID.map(String.init) ?? "missing")"
                            + " first-outcome=\(firstOutcome) second-outcome=\(secondOutcome)"
                            + " decision=\(decision)")
                        switch decision {
                        case .alreadySwitched:
                            // Still only one gesture was sent.
                            continue
                        case .keyboard:
                            break
                        case .abort:
                            return .failure(SwitchFailure(
                                "瞬時切り替え後の状態が不明、またはSpace/モニターが変化しました。"
                                + "二重移動を避けるためキーボードは送信せず中断しました。"))
                        }
                    }
                }

                // Keyboard after a gesture failure is limited to this
                // activation. For a pair, the callback keeps its remaining
                // display on the keyboard path too. A new activation retries.
                if activeMode == .instant {
                    markInstantFallback(instantPosted
                        ? "stable-unmoved-after-gesture-timeout"
                        : "gesture-unavailable-or-not-posted")
                }

                // An instant attempt may wait almost a second. If the user
                // moved the cursor to another display during that wait,
                // do not route the keyboard fallback to the wrong screen.
                guard let fallbackPointer = CGEvent(source: nil)?.location,
                      displayBounds.contains(fallbackPointer) else {
                    SpaceSwitchDiagnostics.record("fallback aborted: pointer left target display")
                    return .failure(SwitchFailure(
                        "キー送信前にカーソルが対象モニターを離れたため中断しました。"))
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
                    beforeOthers: beforeOthers, timeout: transitionTimeout
                ) {
                case .confirmed: break
                case .wrongSpace:
                    return .failure(SwitchFailure(
                        "予定とは異なるSpaceへ移動しました。これ以上の自動切り替えを停止しました。"))
                case .wrongDisplay:
                    return .failure(SwitchFailure(
                        "キー操作が別モニターに作用しました。追加操作を停止しました。診断ログを確認してください。"))
                case .disconnected:
                    return .failure(SwitchFailure("切り替え中にモニターを認識できなくなりました。"))
                case .timedOut:
                    return .failure(SwitchFailure(
                        "Spaceの移動を確認できません。物理キーボードの⌃+←/→で移動できるか確認してください。手動操作が成功する場合、ONIWAのキー送信またはモニター判定が原因の可能性があります。"))
                }
            }
        }

        // A finite budget prevents loops if macOS continuously reorders the
        // desktops. The last observed UUID/ID is never mistaken for success.
        SpaceSwitchDiagnostics.record(
            "step-limit target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
            + " expected=\(target.systemID) limit=\(maxSteps)")
        return .failure(SwitchFailure(
            "Spaceの並び替えが続き、安全な移動回数の上限に達しました。"))
    }


    /// AXPress acknowledges a click, not Space arrival. During the
    /// Mission Control overlay SkyLight can temporarily report overlay Space
    /// IDs on both monitors (observed on macOS 26.6, 2026-10-31). Those IDs
    /// are provisional, including unexpected *target* IDs. Wait for the
    /// requested target, then perform the full settled-display comparison
    /// before allowing another Space switch. Never issue a fallback gesture.
    private func waitForDirectArrival(_ target: SpaceEntry, reader: SpaceReader,
                                      initial: [DisplayGroup]) -> Result<Void, Error> {
        let baseline = initial.first(where: { $0.id == target.displayID })?.currentID
        let otherDisplays = initial.filter { $0.id != target.displayID }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + 3.0
        var lastCurrent: UInt64? = baseline
        var previousProvisionalOtherChanges: [String] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            let displays = reader.displays(includeAppNames: false)
            guard let live = displays.first(where: { $0.id == target.displayID }),
                  live.spaces.filter({ $0.identity == target.identity }).count == 1 else {
                SpaceSwitchDiagnostics.record("mc-direct arrival: target display/UUID missing")
                return .failure(SwitchFailure(
                    "Mission Control移動中に対象Spaceの識別情報が変化しました。"))
            }

            // Do not reject an in-progress AXPress because Mission Control
            // momentarily changes a different monitor's Current Space ID.
            // Record these samples for diagnosis; verify *all* displays after
            // the 850ms settle interval before starting a second pair move.
            let othersChanged: [String] = otherDisplays.compactMap { original in
                let actual = displays.first(where: { $0.id == original.id })?.currentID
                guard actual != original.currentID else { return nil }
                return "\(SpaceSwitchDiagnostics.shortDisplay(original.id)):"
                    + "\(original.currentID.map(String.init) ?? "missing")->"
                    + "\(actual.map(String.init) ?? "missing")"
            }.sorted()
            if othersChanged != previousProvisionalOtherChanges {
                if othersChanged.isEmpty {
                    SpaceSwitchDiagnostics.record("mc-direct provisional-other restored")
                } else {
                    SpaceSwitchDiagnostics.record(
                        "mc-direct provisional-other changes=\(othersChanged)")
                }
                previousProvisionalOtherChanges = othersChanged
            }
            let current = live.currentID
            if current != lastCurrent {
                SpaceSwitchDiagnostics.record(
                    "mc-direct arrival-change elapsed="
                    + "\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))ms"
                    + " previous=\(lastCurrent.map(String.init) ?? "unknown")"
                    + " current=\(current.map(String.init) ?? "unknown")")
                lastCurrent = current
            }
            switch MissionControlDirectObservation.arrival(
                targetDisplay: target.displayID, expectedTarget: target.systemID,
                after: currentSpaceIDs(displays)) {
            case .arrived:
                SpaceSwitchDiagnostics.record(
                    "mc-direct arrived target=\(target.systemID) latency="
                    + "\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))ms"
                    + " provisionalOthers=\(othersChanged)")
                return .success(())
            case .waiting, .displayUnavailable:
                // The overlay may temporarily present Desktop 1 or an
                // unavailable current ID. If it does not reach the target
                // within three seconds, time out without further actions.
                break
            }
        }
        SpaceSwitchDiagnostics.record(
            "mc-direct arrival-timeout target=\(target.systemID)"
            + " actual=\(lastCurrent.map(String.init) ?? "unknown")"
            + " provisionalOthers=\(previousProvisionalOtherChanges)")
        return .failure(SwitchFailure(
            "Mission Controlの操作後3秒以内に目的のSpaceへの移動を確認できませんでした。"
            + "誤移動の可能性があるため追加操作は行いません。診断ログを確認してください。"))
    }

    /// The read-only Current Space ID may update ahead of the visible desktop.
    /// A second sample prevents reporting immediate success if the Space keeps
    /// changing. Also capture what ONIWA associates with each visible Space:
    /// an ID-confirmed switch cannot prove the selected label was correct.
    private func verifySettledTarget(_ target: SpaceEntry,
                                     reader: SpaceReader,
                                     useInstant: Bool = false) -> Result<Void, Error> {
        // Observe beyond the documented/reproduced ~400 ms late Dock yank;
        // the SkyLight current ID can initially look correct.
        // Fast gestures can update the SkyLight current ID before Dock's
        // delayed app activation or a previous gesture finishes. Sample the
        // settling interval without changing the fast-path transition logic.
        // Ordinary keyboard switching retains its single 850ms readback.
        let sampleTimes: [TimeInterval] = useInstant
            ? [0.15, 0.35, 0.60, 0.85] : [0.85]
        let startedAt = ProcessInfo.processInfo.systemUptime
        var live: [DisplayGroup] = []
        for scheduledAt in sampleTimes {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            Thread.sleep(forTimeInterval: max(0, scheduledAt - elapsed))
            live = reader.displays(includeAppNames: false)
            if useInstant {
                let measuredMS = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                let current = live.first(where: { $0.id == target.displayID })?.currentID
                SpaceSwitchDiagnostics.record(
                    "single-settle-sample t=\(measuredMS)ms "
                    + "display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
                    + "expected=\(target.systemID) "
                    + "current=\(current.map(String.init) ?? "missing") "
                    + "layout=\(traceLayout(live))")
            }
        }
        let targetDisplay = live.first(where: { $0.id == target.displayID })
        let actual = targetDisplay?.currentID
        let matching = targetDisplay?.spaces.filter { $0.identity == target.identity } ?? []
        SpaceSwitchDiagnostics.record(
            "single-settled display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
            + "expected=\(target.systemID) current=\(actual.map(String.init) ?? "missing") "
            + "uuidMatchCount=\(matching.count)"
        )
        // A target may have been deleted or recreated after the last step.
        guard actual == target.systemID, matching.count == 1 else {
            SpaceSwitchDiagnostics.record("single-settled FAILED: current or identity changed")
            return .failure(SwitchFailure(
                "切り替え直後にSpaceの状態が変わりました。"
                + "目的のSpaceを確認できないため、完了扱いにしません。"))
        }
        traceSpaceMapping(target, reader: reader)
        return .success(())
    }

    /// Only process names, manual labels, Space IDs and short UUIDs. No window
    /// titles, browser tabs or search queries. This helps distinguish a
    /// wrong Space *selection* from a wrong OS-level *transition*.
    private func traceSpaceMapping(_ target: SpaceEntry, reader: SpaceReader) {
        let live = reader.displays()
        let store = SpaceLabelStore()
        guard let group = live.first(where: { $0.id == target.displayID }) else {
            SpaceSwitchDiagnostics.record("space-map missing display")
            return
        }
        for space in group.spaces {
            let label = store.label(for: space.identity)?.name ?? ""
            let labelText = SpaceSwitchDiagnostics.safe(label)
            let apps = space.appNames.prefix(4).map(SpaceSwitchDiagnostics.safe)
                .joined(separator: ",")
            let uuid = space.identity.uuid.map { String($0.prefix(8)) } ?? "none"
            SpaceSwitchDiagnostics.record(
                "space-map display=\(SpaceSwitchDiagnostics.shortDisplay(space.displayID)) "
                + "id=\(space.systemID) uuid=\(uuid) "
                + "current=\(space.isCurrent) "
                + "name=[\(labelText)] apps=[\(apps)]"
            )
        }
    }

    private enum StepOutcome {
        case confirmed
        case wrongSpace
        case wrongDisplay
        case disconnected
        case timedOut
    }

    private func currentSpaceIDs(_ groups: [DisplayGroup]) -> [String: UInt64] {
        var ids: [String: UInt64] = [:]
        for group in groups {
            if let id = group.currentID { ids[group.id] = id }
        }
        return ids
    }

    /// Warp changes the visible pointer but sends no movement event. To update
    /// Dock's per-display routing, also post a genuine mouseMoved event.
    /// Never synthesize a click or give focus to an unrelated window.
    private func routePointer(to bounds: CGRect, displayID: String) -> Bool {
        let initial = CGEvent(source: nil)?.location
        let point: CGPoint
        if let initial, bounds.insetBy(dx: 2, dy: 2).contains(initial) {
            point = CGPoint(x: initial.x + (initial.x < bounds.midX ? 1 : -1),
                            y: initial.y)
        } else {
            let middle = CGPoint(x: bounds.midX, y: bounds.midY)
            guard CGWarpMouseCursorPosition(middle) == .success else {
                SpaceSwitchDiagnostics.record("cursor warp failed")
                return false
            }
            point = CGPoint(x: middle.x + 1, y: middle.y)
        }
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left)
        else {
            SpaceSwitchDiagnostics.record("mouseMoved event creation failed")
            return false
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.14)
        let finalPointer = CGEvent(source: nil)?.location
        let positioned = finalPointer.map { bounds.contains($0) } ?? false
        SpaceSwitchDiagnostics.record(
            "cursor-target=\(SpaceSwitchDiagnostics.shortDisplay(displayID)) "
            + "mouseMoved=true positioned=\(positioned)")
        return positioned
    }

    private func waitForNeighbor(previous: UInt64, expected: UInt64,
                                 displayID: String, reader: SpaceReader,
                                 beforeOthers: [String: UInt64],
                                 timeout: TimeInterval) -> StepOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            let displays = reader.displays(includeAppNames: false)
            let observed = currentSpaceIDs(displays)
            let outcome = SpaceSwitchObservation.evaluate(
                targetDisplay: displayID, beforeTarget: previous,
                expectedTarget: expected, beforeOthers: beforeOthers,
                after: observed)
            switch outcome {
            case .confirmed:
                SpaceSwitchDiagnostics.record(
                    "confirmed target=\(SpaceSwitchDiagnostics.shortDisplay(displayID)) "
                    + "from=\(previous) to=\(expected) "
                    + "latency=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))ms")
                return .confirmed
            case .waiting:
                break
            case .wrongTarget:
                let actual = observed[displayID].map(String.init) ?? "missing"
                SpaceSwitchDiagnostics.record(
                    "WRONG-TARGET display=\(SpaceSwitchDiagnostics.shortDisplay(displayID)) "
                    + "from=\(previous) expected=\(expected) actual=\(actual)")
                return .wrongSpace
            case .otherDisplayChanged:
                let changes = beforeOthers.map { key, previousID in
                    "\(SpaceSwitchDiagnostics.shortDisplay(key)):\(previousID)->\(observed[key].map(String.init) ?? "missing")"
                }.joined(separator: " ")
                SpaceSwitchDiagnostics.record(
                    "WRONG-DISPLAY target=\(SpaceSwitchDiagnostics.shortDisplay(displayID)) "
                    + "other=\(changes)")
                return .wrongDisplay
            case .displayUnavailable:
                SpaceSwitchDiagnostics.record("missing display during step")
                return .disconnected
            }
        }
        SpaceSwitchDiagnostics.record(
            "timeout target=\(SpaceSwitchDiagnostics.shortDisplay(displayID)) "
            + "from=\(previous) expected=\(expected)")
        return .timedOut
    }

    private struct SwitchFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

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

        // Opt-in experiment only. The established two-session path below
        // stays intact for ordinary users and as a manual fallback.
        if MissionControlDirectSettings.enabled
            && MissionControlPairSingleSessionSettings.enabled {
            return performPairSingleSession(pair, before: before)
        }

        // Snapshot unrelated displays so we can detect an unintended change.
        var untouched: [String: UInt64] = [:]
        for display in before
            where display.id != pair.first.displayID && display.id != pair.second.displayID {
            if let current = display.currentID { untouched[display.id] = current }
        }

        switch performSwitch(first) {
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
        switch performSwitch(second) {
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

    /// In the experimental mode both AX targets are prepared from one
    /// Mission Control session. There is deliberately no retry or fallback:
    /// once an AXPress is sent, a second session could produce a wrong move.
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
              before.allSatisfy({ $0.currentID != nil }) else {
            return .failure(SwitchFailure(
                "試験モードで両画面のSpaceを一意に識別できません。"))
        }

        // Unrelated monitors must stay on their original Space.
        let untouched = currentSpaceIDs(before.filter {
            $0.id != first.displayID && $0.id != second.displayID
        })
        SpaceSwitchDiagnostics.record(
            "mc-pair-once initial \(traceLayout(before))")
        let bothAlreadyCurrent = firstDisplay.currentID == first.systemID
            && secondDisplay.currentID == second.systemID
        if !bothAlreadyCurrent {
            switch MissionControlDirectSwitch.pressPairInOneSession(
                first: first, second: second, reader: reader, original: before) {
            case .failure(let error):
                SpaceSwitchDiagnostics.record(
                    "mc-pair-once press-failed: \(error.localizedDescription)")
                return .failure(SwitchFailure(
                    "Mission Control一回方式が失敗しました。"
                    + "一方の画面だけ動いた可能性があります。"
                    + "自動再試行は行いません。\(error.localizedDescription)"))
            case .success:
                break
            }
        }
        // A successful AXPress only means that macOS accepted an action.
        // Each target must be reached and remain stable, even if the other
        // monitor temporarily shows a Mission Control overlay Space.
        if !bothAlreadyCurrent {
            let deadline = ProcessInfo.processInfo.systemUptime + 3.0
            var arrived = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
                let current = reader.displays(includeAppNames: false)
                guard SpacePairResolver.resolve(
                    pair, in: current.flatMap(\.spaces).map(\.identity)) != nil else {
                    SpaceSwitchDiagnostics.record(
                        "mc-pair-once abort: target identity disappeared")
                    return .failure(SwitchFailure(
                        "切り替え中にセットのSpace構成が変わりました。"))
                }
                let ids = currentSpaceIDs(current)
                let phase = MissionControlPairObservation.arrival(
                    firstDisplay: first.displayID, firstTarget: first.systemID,
                    secondDisplay: second.displayID, secondTarget: second.systemID,
                    current: ids)
                if phase == .arrived {
                    SpaceSwitchDiagnostics.record(
                        "mc-pair-once arrived \(traceLayout(current))")
                    arrived = true
                    break
                }
            }
            guard arrived else {
                SpaceSwitchDiagnostics.record(
                    "mc-pair-once arrival-timeout \(traceLayout(reader.displays(includeAppNames: false)))")
                return .failure(SwitchFailure(
                    "Mission Control一回方式で両画面の到達を3秒以内に確認できませんでした。"
                    + "自動で切り替え直しません。"))
            }
        }

        // Check at multiple points to capture delayed snaps that occur
        // hundreds of milliseconds after an apparently correct transition.
        let startedAt = ProcessInfo.processInfo.systemUptime
        var settled: [DisplayGroup] = []
        for sample in [0.15, 0.35, 0.60, 0.85] {
            Thread.sleep(forTimeInterval: max(
                0, sample - (ProcessInfo.processInfo.systemUptime - startedAt)))
            settled = reader.displays(includeAppNames: false)
            SpaceSwitchDiagnostics.record(
                "mc-pair-once settle-sample t=\(Int(sample * 1000))ms"
                + " \(traceLayout(settled))")
        }
        guard SpacePairResolver.resolve(
            pair, in: settled.flatMap(\.spaces).map(\.identity)) != nil else {
            return .failure(SwitchFailure(
                "切り替え後にSpaceの識別子が変化しました。"))
        }
        let outcome = MissionControlPairObservation.settled(
            firstDisplay: first.displayID, firstTarget: first.systemID,
            secondDisplay: second.displayID, secondTarget: second.systemID,
            untouched: untouched, current: currentSpaceIDs(settled))
        guard outcome == .confirmed else {
            SpaceSwitchDiagnostics.record(
                "mc-pair-once FAILED outcome=\(outcome)")
            return .failure(SwitchFailure(
                "Mission Control一回方式の完了後も両画面が正しいSpaceにありません"
                + "（\(outcome)）。追加操作は行いません。"))
        }
        SpaceSwitchDiagnostics.record("mc-pair-once complete confirmed")
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

        if MissionControlDirectSettings.enabled {
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
                return verifySettledTarget(target, reader: reader)
            case let .move(direction, nextSpaceID):
                SpaceSwitchDiagnostics.record(
                    "step target=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID)) "
                    + "from=\(current) to=\(nextSpaceID) "
                    + "direction=\(direction == .right ? "right" : "left") "
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
                        beforeOthers: beforeOthers, timeout: 0.9
                    ) {
                    case .confirmed:
                        // Optional A/B experiment: wait beyond the observed
                        // 150-350ms delayed Space snap-back before posting
                        // another gesture. This is NOT a permanent fast-mode
                        // speed change; the menu toggle defaults to OFF.
                        if InstantSwitchSettings.pacingProbeEnabled {
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
                                    + "診断のため次のジェスチャーを送らず停止しました。"))
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
                        // A delayed/unsupported synthetic gesture might still
                        // be in flight. Give the system an extra observation,
                        // and never emit Ctrl+arrow after movement was seen.
                        guard let latest = reader.displays(includeAppNames: false)
                            .first(where: { $0.id == target.displayID }) else {
                            return .failure(SwitchFailure(
                                "対象モニターが接続解除されました。"))
                        }
                        // Do not fall back if the first attempt moved another
                        // display. That would otherwise produce two wrong steps.
                        let outcome = SpaceSwitchObservation.evaluate(
                            targetDisplay: target.displayID, beforeTarget: current,
                            expectedTarget: nextSpaceID, beforeOthers: beforeOthers,
                            after: currentSpaceIDs(reader.displays(includeAppNames: false))
                        )
                        guard outcome == .waiting || outcome == .confirmed else {
                            SpaceSwitchDiagnostics.record("fallback blocked: \(outcome)")
                            return .failure(SwitchFailure(
                                "瞬時切り替えが別モニターに作用したか、状態を確認できません。追加操作を停止しました。"))
                        }
                        switch InstantSwitchPolicy.fallbackDecision(
                            previous: current, expected: nextSpaceID,
                            observed: latest.currentID,
                            orderUnchanged: latest.spaces.map(\.systemID) == order
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
                                     reader: SpaceReader) -> Result<Void, Error> {
        // Observe beyond the documented/reproduced ~400 ms late Dock yank;
        // the SkyLight current ID can initially look correct.
        // Fast gestures can update the SkyLight current ID before Dock's
        // delayed app activation or a previous gesture finishes. Sample the
        // settling interval without changing the fast-path transition logic.
        // Ordinary keyboard switching retains its single 850ms readback.
        let sampleTimes: [TimeInterval] = InstantSwitchSettings.enabled
            ? [0.15, 0.35, 0.60, 0.85] : [0.85]
        let startedAt = ProcessInfo.processInfo.systemUptime
        var live: [DisplayGroup] = []
        for scheduledAt in sampleTimes {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            Thread.sleep(forTimeInterval: max(0, scheduledAt - elapsed))
            live = reader.displays(includeAppNames: false)
            if InstantSwitchSettings.enabled {
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

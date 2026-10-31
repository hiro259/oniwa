import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Separate opt-in mode. It does not change the existing instant/keyboard path.
enum MissionControlDirectSettings {
    static let key = "oniwa.missionControlDirectEnabled"
    static let readinessWaitKey = "oniwa.missionControlReadinessWaitMilliseconds"
    static let defaultReadinessWaitMilliseconds = 300
    // 100ms is experimental; cap custom values so the AX readiness timeout
    // is not accidentally exceeded by a very large saved value.
    static let minimumReadinessWaitMilliseconds = 100
    static let maximumReadinessWaitMilliseconds = 1_000

    static func isValidReadinessWait(_ value: Int) -> Bool {
        (minimumReadinessWaitMilliseconds...maximumReadinessWaitMilliseconds).contains(value)
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The delay after the complete AX thumbnail list is first observed.
    /// This is NOT the entire duration Mission Control remains visible.
    static var readinessWaitMilliseconds: Int {
        get {
            guard let value = UserDefaults.standard.object(forKey: readinessWaitKey) as? Int,
                  isValidReadinessWait(value) else {
                return defaultReadinessWaitMilliseconds
            }
            return value
        }
        set {
            guard isValidReadinessWait(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: readinessWaitKey)
        }
    }
}

/// Experimental direct Space selection via Mission Control's AXPress action.
///
/// See Hammerspoon hs.spaces.gotoSpace and Hammerspoon issue #3897:
/// macOS 26: the tree is owned by Dock. macOS 27: WindowManager.
/// A button has no stable Space ID, so we NEVER press unless the current
/// SkyLight order and the actual thumbnail count match exactly.
/// No private Space setters, blind index guesses, or fallback swipes.
enum MissionControlDirectSwitch {
    private static let listID = "mc.spaces.list"
    private static let displayID = "mc.display"
    private static let maximumDepth = 7

    private struct DirectFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func press(target: SpaceEntry, reader: SpaceReader,
                      original: [DisplayGroup]) -> Result<Void, Error> {
        guard AXIsProcessTrusted() else {
            return .failure(DirectFailure(
                "Mission Control直接移動にはアクセシビリティの許可が必要です。"
                + "システム設定でONIWAの許可を確認してください。"))
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion == 26 || version.majorVersion == 27 else {
            return .failure(DirectFailure(
                "Mission Control直接移動はmacOS 26/27のみ試験対応しています。"))
        }
        guard let group = original.first(where: { $0.id == target.displayID }),
              group.spaces.filter({ $0.identity == target.identity }).count == 1,
              let targetIndex = group.spaces.firstIndex(where: {
                  $0.identity == target.identity
              }),
              let bounds = reader.displayBounds(for: target.displayID),
              let physicalDisplay = screenNumber(for: target.displayID) else {
            return .failure(DirectFailure(
                "移動先Spaceまたはモニターを一意に特定できません。"))
        }

        // Mission Control may already be open. Do not toggle it closed.
        var openedByONIWA = false
        if candidateDisplayLists().isEmpty {
            guard openMissionControl() else {
                return .failure(DirectFailure(
                    "Mission Controlを開けませんでした。診断ログを確認してください。"))
            }
            openedByONIWA = true
        }
        SpaceSwitchDiagnostics.record(
            "mc-direct start display=\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
            + " target=\(target.systemID) index=\(targetIndex)"
            + " expectedCount=\(group.spaces.count) opened=\(openedByONIWA)"
            + " os=\(version.majorVersion).\(version.minorVersion)")

        // AX elements are created only after Mission Control appears.
        // Poll for readiness; do not assume a fixed animation duration.
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        var lastReason = "AXツリーがまだ表示されていません"
        // The user-configurable wait begins when the complete thumbnail list
        // first appears. Even 100ms is experimental; keep all identity checks.
        let readinessWaitMilliseconds = MissionControlDirectSettings.readinessWaitMilliseconds
        let readinessWaitSeconds = Double(readinessWaitMilliseconds) / 1_000
        SpaceSwitchDiagnostics.record(
            "mc-direct readiness-setting waitMs=\(readinessWaitMilliseconds)")
        var readySince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let candidates = candidateDisplayLists()
            if !candidates.isEmpty {
                let matches = candidates.filter {
                    matchesDisplay($0.display, number: physicalDisplay, bounds: bounds)
                }
                if matches.count > 1 {
                    lastReason = "対象ディスプレイのAX要素が複数あります"
                    break
                }
                if let match = matches.first {
                    // Mission Control can reorder or recreate Spaces while open.
                    // Recheck identities/order and require 1:1 thumbnail mapping.
                    let current = reader.displays(includeAppNames: false)
                    guard let currentGroup = current.first(where: { $0.id == target.displayID }),
                          currentGroup.spaces.map(\.identity) == group.spaces.map(\.identity),
                          currentGroup.spaces.indices.contains(targetIndex),
                          currentGroup.spaces[targetIndex].identity == target.identity else {
                        lastReason = "Mission Control表示中にSpaceの構成が変わりました"
                        break
                    }
                    let buttons = children(of: match.list).filter {
                        stringAttribute($0, "AXRole") == "AXButton"
                    }
                    guard buttons.count == currentGroup.spaces.count else {
                        lastReason = "サムネイル数が一致しません AX=\(buttons.count)"
                            + " SkyLight=\(currentGroup.spaces.count)"
                        readySince = nil
                        // A partially constructed list may fill in shortly.
                        Thread.sleep(forTimeInterval: 0.06)
                        continue
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if readySince == nil {
                        readySince = now
                        SpaceSwitchDiagnostics.record(
                            "mc-direct list-ready count=\(buttons.count)"
                            + " index=\(targetIndex)")
                    }
                    guard let firstReady = readySince,
                          now - firstReady >= readinessWaitSeconds else {
                        Thread.sleep(forTimeInterval: 0.06)
                        continue
                    }
                    SpaceSwitchDiagnostics.record(
                        "mc-direct ax-stable t=\(Int((now - firstReady) * 1000))ms"
                        + " configuredMs=\(readinessWaitMilliseconds)")
                    // Only press after the target index is proved by the live
                    // SkyLight roster and the exact thumbnail count.
                    let action = AXUIElementPerformAction(
                        buttons[targetIndex], kAXPressAction as CFString)
                    SpaceSwitchDiagnostics.record(
                        "mc-direct axpress display="
                        + "\(SpaceSwitchDiagnostics.shortDisplay(target.displayID))"
                        + " index=\(targetIndex) total=\(buttons.count)"
                        + " error=\(action.rawValue)")
                    guard action == .success else {
                        return .failure(DirectFailure(
                            "Mission ControlのSpaceボタンを押せませんでした"
                            + "（AXエラー \(action.rawValue)）。"))
                    }
                    return .success(())
                }
                lastReason = "対象ディスプレイのmc.displayが見つかりません"
                readySince = nil
            } else {
                readySince = nil
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        SpaceSwitchDiagnostics.record("mc-direct abort reason=\(lastReason)")
        // Never send a fallback gesture: Mission Control may still be open.
        return .failure(DirectFailure(
            "Mission Control直接移動を安全に実行できませんでした（\(lastReason)）。"
            + " 必要ならEscapeキーでMission Controlを閉じてください。"))
    }

    private static func openMissionControl() -> Bool {
        let paths = ["/System/Applications/Mission Control.app",
                     "/System/Library/CoreServices/Mission Control.app"]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) })
        else {
            SpaceSwitchDiagnostics.record("mc-direct open: app bundle not found")
            return false
        }
        var opened = false
        // NSWorkspace operations are performed on the main queue.
        DispatchQueue.main.sync {
            opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        SpaceSwitchDiagnostics.record("mc-direct open path=\(path) result=\(opened)")
        return opened
    }

    private static func screenNumber(for uuid: String) -> UInt32? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let value = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)
            else { continue }
            let identifier = CFUUIDCreateString(nil, value.takeRetainedValue()) as String
            if identifier.caseInsensitiveCompare(uuid) == .orderedSame {
                return number.uint32Value
            }
        }
        return nil
    }

    private struct DisplayList {
        let display: AXUIElement
        let list: AXUIElement
    }

    private static func candidateDisplayLists() -> [DisplayList] {
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let bundle = version >= 27 ? "com.apple.WindowManager" : "com.apple.dock"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .flatMap { app in
                let root = AXUIElementCreateApplication(app.processIdentifier)
                return descendants(withIdentifier: displayID, from: root, depth: maximumDepth)
                    .compactMap { display -> DisplayList? in
                        guard let list = descendants(
                            withIdentifier: listID, from: display, depth: 4
                        ).first else { return nil }
                        return DisplayList(display: display, list: list)
                    }
            }
    }

    private static func matchesDisplay(_ element: AXUIElement,
                                       number: UInt32, bounds: CGRect) -> Bool {
        if let explicit = attribute(element, "AXDisplayID") as? NSNumber {
            return explicit.uint32Value == number
        }
        guard let raw = attribute(element, "AXFrame"),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        let frameValue = unsafeBitCast(raw, to: AXValue.self)
        var frame = CGRect.zero
        guard AXValueGetValue(frameValue, .cgRect, &frame) else { return false }
        let intersection = frame.intersection(bounds)
        guard !intersection.isNull, frame.width > 0, frame.height > 0 else {
            return false
        }
        return intersection.width * intersection.height
            / (frame.width * frame.height) > 0.90
    }

    private static func descendants(withIdentifier id: String, from root: AXUIElement,
                                    depth: Int) -> [AXUIElement] {
        guard depth >= 0 else { return [] }
        if stringAttribute(root, "AXIdentifier") == id { return [root] }
        guard depth > 0 else { return [] }
        return children(of: root).flatMap {
            descendants(withIdentifier: id, from: $0, depth: depth - 1)
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(element, kAXChildrenAttribute as String)
        else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }
}

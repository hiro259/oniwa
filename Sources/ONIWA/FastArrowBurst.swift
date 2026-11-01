import AppKit
import CoreGraphics
import Foundation
import ONIWACore

/// Separate experiment path: mimics repeatedly pressing physical Control+Arrow
/// without waiting for intermediate Space ID transitions. Does NOT call SkyLight
/// setters. Returning a post count is not proof of a completed Space switch.
enum FastArrowBurst {
    struct Posting {
        let posted: Int
        let elapsedMS: Int
        let reason: String?
    }

    static func post(
        direction: ArrowBurstPlan.Direction,
        steps: Int,
        intervalMS: Int,
        bounds: CGRect
    ) -> Posting {
        guard steps > 0, steps <= 12, (50...100).contains(intervalMS) else {
            return Posting(posted: 0, elapsedMS: 0, reason: "invalid-burst-settings")
        }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            return Posting(posted: 0, elapsedMS: 0, reason: "post-event-access-denied")
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return Posting(posted: 0, elapsedMS: 0, reason: "hid-source-unavailable")
        }

        let arrowCode: CGKeyCode = direction == .right ? 124 : 123
        let controlCode: CGKeyCode = 59
        let arrowFlags: CGEventFlags = [
            .maskControl, .maskSecondaryFn, .maskNumericPad
        ]
        let start = ProcessInfo.processInfo.systemUptime
        var count = 0

        for index in 0..<steps {
            // Start-to-start cadence (not a fixed delay after keyUp).
            let due = start + Double(index * intervalMS) / 1000
            let now = ProcessInfo.processInfo.systemUptime
            if due > now { Thread.sleep(forTimeInterval: due - now) }

            guard let cursor = CGEvent(source: nil)?.location,
                  bounds.contains(cursor) else {
                return Posting(
                    posted: count,
                    elapsedMS: Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
                    reason: "pointer-left-display")
            }

            guard let ctrlDown = CGEvent(
                    keyboardEventSource: source, virtualKey: controlCode, keyDown: true),
                  let arrowDown = CGEvent(
                    keyboardEventSource: source, virtualKey: arrowCode, keyDown: true),
                  let arrowUp = CGEvent(
                    keyboardEventSource: source, virtualKey: arrowCode, keyDown: false),
                  let ctrlUp = CGEvent(
                    keyboardEventSource: source, virtualKey: controlCode, keyDown: false)
            else {
                return Posting(
                    posted: count,
                    elapsedMS: Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
                    reason: "hid-key-event-unavailable")
            }
            ctrlDown.flags = .maskControl
            arrowDown.flags = arrowFlags
            arrowUp.flags = arrowFlags
            ctrlUp.flags = []

            ctrlDown.post(tap: .cghidEventTap)
            arrowDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
            arrowUp.post(tap: .cghidEventTap)
            ctrlUp.post(tap: .cghidEventTap)
            count += 1
        }
        return Posting(
            posted: count,
            elapsedMS: Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
            reason: nil)
    }
}

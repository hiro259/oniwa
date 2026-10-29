import CoreGraphics
import Foundation
import Darwin
import ONIWACore

/// ONIWA-only near-instant native Space transition. This is deliberately *not*
/// an event tap and does not change the system Ctrl+arrow bindings or swipes.
///
/// Gesture format adapted from Max Mathys' MIT-licensed noswoosh:
/// https://github.com/mmathys/noswoosh (see THIRD_PARTY_NOTICES.md).
/// Fields and the macOS 27 IOHID payload are undocumented. Only known-good OS
/// versions are eligible, and the caller MUST verify the resulting Space ID.
enum InstantSpaceGesture {
    private enum Phase: Int64, CaseIterable {
        case began = 1
        case changed = 2
        case ended = 4
    }

    private static func field(_ id: UInt32) -> CGEventField {
        unsafeBitCast(id, to: CGEventField.self)
    }

    private static let typeField = field(55)
    private static let hidTypeField = field(110)
    private static let maskField = field(115)
    private static let motionField = field(123)
    private static let progressField = field(124)
    private static let positionXField = field(125)
    private static let positionYField = field(126)
    private static let velocityXField = field(129)
    private static let velocityYField = field(130)
    private static let phaseField = field(132)

    private static let dockControlType: Int64 = 30
    private static let gestureType: Int64 = 29
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    private static let ioHIDPayloadTag = 4205
    private static let oniwaEventTag: Int64 = 0x4F4E_4957 // 'ONIW'

    static var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return InstantSwitchPolicy.supportsInstant(
            major: version.majorVersion, minor: version.minorVersion)
    }

    /// Returns true only if the *complete event sequence* was constructed and
    /// posted. The system does not acknowledge a posted gesture, so this is NOT
    /// proof the Space moved. The caller is responsible for verifying it.
    static func post(right: Bool) -> Bool {
        guard isSupported, CGPreflightPostEventAccess() else { return false }

        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 27 {
            let naturalScroll = CFPreferencesCopyAppValue(
                "com.apple.swipescrolldirection" as CFString,
                kCFPreferencesAnyApplication) as? Bool ?? true
            // macOS 27 inverts the direction used by the pre-27 gesture.
            let sign = naturalScroll ? 1.0 : -1.0
            var pairs: [(CGEvent, CGEvent)] = []
            for phase in Phase.allCases {
                guard let event = makeDockEvent(phase: phase, right: right,
                                                macOS27: true, sign: sign),
                      let augmented = augment(event),
                      let companion = CGEvent(source: nil) else { return false }
                augmented.setIntegerValueField(.eventSourceUserData, value: oniwaEventTag)
                companion.setIntegerValueField(typeField, value: gestureType)
                companion.setIntegerValueField(.eventSourceUserData, value: oniwaEventTag)
                pairs.append((augmented, companion))
            }
            for (event, companion) in pairs {
                event.post(tap: .cgSessionEventTap)
                companion.post(tap: .cgSessionEventTap)
            }
        } else {
            var events: [CGEvent] = []
            for phase in Phase.allCases {
                guard let event = makeDockEvent(phase: phase, right: right,
                                                macOS27: false, sign: 1.0)
                else { return false }
                events.append(event)
            }
            events.forEach { $0.post(tap: .cgSessionEventTap) }
        }
        return true
    }

    private static func makeDockEvent(phase: Phase, right: Bool,
                                      macOS27: Bool, sign: Double) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(typeField, value: dockControlType)
        event.setIntegerValueField(hidTypeField, value: dockSwipeHIDType)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        event.setIntegerValueField(motionField, value: horizontalMotion)
        event.setIntegerValueField(.eventSourceUserData, value: oniwaEventTag)
        // Avoid FLT_TRUE_MIN: it loses its sign on Apple Silicon.
        let direction = right ? 1.0 : -1.0
        let progress = 1e-4 * direction * (macOS27 ? -sign : 1.0)
        event.setDoubleValueField(progressField, value: progress)
        if macOS27 {
            event.setDoubleValueField(positionXField, value: 0.1)
            if phase == .ended {
                event.setDoubleValueField(velocityXField,
                                          value: -9999.0 * direction * sign)
            }
        } else {
            event.setDoubleValueField(velocityXField, value: 2000.0 * direction)
            event.setDoubleValueField(velocityYField, value: 2000.0 * direction)
        }
        return event
    }

    private static func fixed1616(_ value: Double) -> Int32 {
        let converted = Int32(truncatingIfNeeded: Int64(value * 65536.0))
        if converted == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return converted
    }

    private struct Bytes {
        private(set) var value: [UInt8] = []
        mutating func write(_ number: UInt16) {
            Swift.withUnsafeBytes(of: number.littleEndian) { value.append(contentsOf: $0) }
        }
        mutating func write(_ number: UInt32) {
            Swift.withUnsafeBytes(of: number.littleEndian) { value.append(contentsOf: $0) }
        }
        mutating func write(_ number: UInt64) {
            Swift.withUnsafeBytes(of: number.littleEndian) { value.append(contentsOf: $0) }
        }
        mutating func write(_ number: Int32) {
            write(UInt32(bitPattern: number))
        }
        mutating func zeroDepth() { value.append(contentsOf: [0, 0, 0, 0]) }
        mutating func velocityDepth() { value.append(contentsOf: [1, 0, 0, 0]) }
    }

    /// macOS 27 requires a serialized IOHID queue payload in event field 4205.
    /// Adapted from noswoosh/iss. No private frameworks are linked or written.
    private static func ioHIDPayload(for event: CGEvent) -> [UInt8] {
        let phase = event.getIntegerValueField(phaseField)
        let motion = event.getIntegerValueField(motionField)
        let progress = event.getDoubleValueField(progressField)
        let x = event.getDoubleValueField(positionXField)
        let y = event.getDoubleValueField(positionYField)
        let velocityX = event.getDoubleValueField(velocityXField)
        let velocityY = event.getDoubleValueField(velocityYField)
        let mask = event.getIntegerValueField(maskField)
        let includeVelocity = velocityX != 0 || velocityY != 0 ||
                              phase == Phase.ended.rawValue

        var data = Bytes()
        let timestamp = event.timestamp
        data.write(timestamp != 0 ? timestamp : mach_absolute_time())
        data.write(UInt64(0)) // sender_id
        data.write(UInt32(0)) // options
        data.write(UInt32(0)) // attribute_length
        data.write(UInt32(includeVelocity ? 2 : 1))

        data.write(UInt32(40)) // IOHIDFluidTouchGestureData
        data.write(UInt32(23)) // fluid touch
        data.write(UInt32((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24))
        data.zeroDepth()
        data.write(fixed1616(x))
        data.write(fixed1616(y))
        data.write(Int32(0))
        data.write(UInt32(truncatingIfNeeded: mask))
        data.write(UInt16(truncatingIfNeeded: motion))
        data.write(UInt16(3)) // Dock primary
        data.write(fixed1616(progress))

        if includeVelocity {
            data.write(UInt32(28))
            data.write(UInt32(9)) // IOHID velocity
            data.write(UInt32(0))
            data.velocityDepth()
            data.write(fixed1616(velocityX))
            data.write(fixed1616(velocityY))
            data.write(Int32(0))
        }
        return data.value
    }

    private static func augment(_ event: CGEvent) -> CGEvent? {
        guard let serialized = event.data else { return nil }
        var bytes = [UInt8](serialized as Data)
        guard bytes.count >= 4, Array(bytes.prefix(4)) == [0, 0, 0, 2] else {
            return nil
        }
        let payload = ioHIDPayload(for: event)
        guard payload.count <= Int(UInt16.max) else { return nil }
        let length = payload.count
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(UInt8((ioHIDPayloadTag >> 8) & 0xFF))
        bytes.append(UInt8(ioHIDPayloadTag & 0xFF))
        bytes.append(contentsOf: payload)
        return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
    }
}

/// Settings affect only ONIWA's own switching path, never system-wide gestures.
enum InstantSwitchSettings {
    static let key = "oniwa.instantSwitchEnabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

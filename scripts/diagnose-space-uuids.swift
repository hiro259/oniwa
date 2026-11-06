// Read-only diagnostic for Issue #31: never writes Space preferences or
// sends keyboard events. Prints only display position, Space position/type,
// numeric runtime ID and whether the UUID is present; no raw UUIDs or app names.
import Foundation
import Darwin

typealias Connection = @convention(c) () -> Int32
typealias Layout = @convention(c) (Int32) -> CFArray?

guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
      let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
      let layoutSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces")
else {
    print("SkyLight symbols are not available.")
    exit(1)
}

let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
let layout = unsafeBitCast(layoutSymbol, to: Layout.self)
guard let monitors = layout(connection()) as? [[String: Any]] else {
    print("The managed display topology is unavailable.")
    exit(1)
}

print("ONIWA read-only Space UUID diagnostic (no identifiers or app names)")
for (displayIndex, monitor) in monitors.enumerated() {
    let displayType = (monitor["Display Identifier"] as? String) == "Main"
        ? "Main" : "display"
    print("Display \(displayIndex + 1) (\(displayType)):")
    guard let spaces = monitor["Spaces"] as? [[String: Any]] else {
        print("  No Space records available")
        continue
    }
    var blankOrUnknown = 0
    for record in spaces {
        let raw = record["uuid"]
        if (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            blankOrUnknown += 1
        }
    }
    for (index, record) in spaces.enumerated() {
        let kind = (record["type"] as? NSNumber)?.intValue ?? -1
        let runtimeID = ((record["ManagedSpaceID"] as? NSNumber)
                         ?? (record["id64"] as? NSNumber))?.uint64Value ?? 0
        let uuidStatus: String
        if let raw = record["uuid"] as? String {
            uuidStatus = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "explicit-empty" : "present"
        } else if record["uuid"] == nil {
            uuidStatus = "missing-field"
        } else {
            uuidStatus = "non-string-field"
        }
        let eligible = uuidStatus == "explicit-empty" && kind == 0
            && blankOrUnknown == 1
        print("  Space \(index + 1): type=\(kind) runtimeID=\(runtimeID) UUID=\(uuidStatus) anchorEligible=\(eligible)")
    }
}

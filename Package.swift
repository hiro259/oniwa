// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ONIWA",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ONIWA", targets: ["ONIWA"])],
    targets: [
        .target(name: "ONIWACore"),
        .executableTarget(name: "ONIWA", dependencies: ["ONIWACore"]),
        .testTarget(name: "ONIWACoreTests", dependencies: ["ONIWACore"])
    ]
)

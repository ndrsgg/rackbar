// swift-tools-version: 6.0
import PackageDescription

// Everything Rackbar knows that is not AppKit: the Hetzner API, the merge of
// several tokens under one label, and the ssh config it writes. Foundation
// only, so `swift test` runs on Linux too.
let package = Package(
    name: "RackbarCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "RackbarCore", targets: ["RackbarCore"]),
    ],
    targets: [
        .target(
            name: "RackbarCore",
            resources: [.copy("Resources/demo-fleet.json")]
        ),
        .testTarget(
            name: "RackbarCoreTests",
            dependencies: ["RackbarCore"]
        ),
    ]
)

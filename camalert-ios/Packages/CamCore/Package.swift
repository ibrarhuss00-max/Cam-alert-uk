// swift-tools-version:5.7
import PackageDescription

// CamCore: the camera-alert brain. Foundation only, no UIKit/MapKit, so it can be
// tested on its own with `swift test` (no simulator needed).
let package = Package(
    name: "CamCore",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [
        .library(name: "CamCore", targets: ["CamCore"])
    ],
    targets: [
        .target(name: "CamCore"),
        .testTarget(name: "CamCoreTests", dependencies: ["CamCore"])
    ]
)

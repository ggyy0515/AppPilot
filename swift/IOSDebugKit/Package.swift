// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IOSDebugKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "IOSDebugCore", targets: ["IOSDebugCore"]),
        .library(name: "IOSDebugKit", targets: ["IOSDebugKit"]),
    ],
    targets: [
        .target(name: "IOSDebugCore"),
        .target(name: "IOSDebugKit", dependencies: ["IOSDebugCore"]),
        .testTarget(name: "IOSDebugCoreTests", dependencies: ["IOSDebugCore"]),
        .testTarget(name: "IOSDebugKitTests", dependencies: ["IOSDebugKit", "IOSDebugCore"]),
    ],
    swiftLanguageModes: [.v6]
)

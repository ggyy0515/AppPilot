// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ap-ios-debug-kit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "APIOSDebugCore", targets: ["APIOSDebugCore"]),
        .library(name: "APIOSDebugKit", targets: ["APIOSDebugKit"]),
    ],
    targets: [
        .target(name: "APIOSDebugCore"),
        .target(name: "APIOSDebugKit", dependencies: ["APIOSDebugCore"]),
        .testTarget(name: "APIOSDebugCoreTests", dependencies: ["APIOSDebugCore", "APIOSDebugKit"]),
        .testTarget(name: "APIOSDebugKitTests", dependencies: ["APIOSDebugKit", "APIOSDebugCore"]),
    ]
)

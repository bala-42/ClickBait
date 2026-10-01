// swift-tools-version: 6.0
// ClickBaitCore holds everything that is not macOS-specific: providers, prompting,
// response parsing, models and geometry. No AppKit / SwiftUI imports allowed here.
import PackageDescription

let package = Package(
    name: "ClickBaitCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClickBaitCore", targets: ["ClickBaitCore"])
    ],
    targets: [
        .target(name: "ClickBaitCore"),
        .testTarget(name: "ClickBaitCoreTests", dependencies: ["ClickBaitCore"])
    ]
)

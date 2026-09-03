// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "adaptive-friction-kit",
    // Only platforms CI actually builds are declared. Linux needs no declaration;
    // the demo app's CI builds for `generic/platform=iOS Simulator`.
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "AdaptiveFriction", targets: ["AdaptiveFriction"]),
        .library(name: "AdaptiveFrictionUI", targets: ["AdaptiveFrictionUI"])
    ],
    targets: [
        .target(name: "AdaptiveFriction"),
        .target(name: "AdaptiveFrictionUI", dependencies: ["AdaptiveFriction"]),
        .testTarget(name: "AdaptiveFrictionTests", dependencies: ["AdaptiveFriction"])
    ]
)

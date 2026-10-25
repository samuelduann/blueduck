// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BlueDuckKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlueDuckKit", targets: ["BlueDuckKit"]),
    ],
    targets: [
        .target(name: "BlueDuckKit"),
        .testTarget(name: "BlueDuckKitTests", dependencies: ["BlueDuckKit"]),
    ],
    swiftLanguageVersions: [.v5]
)

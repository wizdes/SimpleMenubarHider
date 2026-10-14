// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SMHCore",
    platforms: [.macOS("27.0")],
    products: [.library(name: "SMHCore", targets: ["SMHCore"])],
    targets: [
        .target(name: "SMHCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SMHCoreTests", dependencies: ["SMHCore"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)

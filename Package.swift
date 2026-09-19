// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "SonosDrop",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SonosDropCore", swiftSettings: swift5),
        .executableTarget(name: "SonosDrop", dependencies: ["SonosDropCore"], swiftSettings: swift5),
        .testTarget(
            name: "SonosDropCoreTests",
            dependencies: ["SonosDropCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift5),
    ]
)

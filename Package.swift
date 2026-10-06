// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "M0110HUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "M0110HUD", path: "Sources/M0110HUD"),
        .testTarget(name: "M0110HUDTests", dependencies: ["M0110HUD"], path: "Tests/M0110HUDTests"),
    ]
)

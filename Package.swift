// swift-tools-version:5.9
import PackageDescription

#if os(Windows)
// The Windows build shares these files with the Mac app. Its C layers are
// Sources/CM0110Win (Win32) and Sources/CM0110Web (WebView2).
let shared = [
    "Announcer.swift",
    "Clipboard/ClipMessage.swift",
    "Clipboard/ClipWire.swift",
    "Config.swift",
    "HUDKind.swift",
    "Presence.swift",
    "ProfileNameSync.swift",
    "Studio/Behaviors.swift",
    "Studio/HIDKeycodes.swift",
    "Studio/Models.swift",
    "Studio/Protobuf.swift",
    "Studio/StudioClient.swift",
    "Studio/StudioProbe.swift",
    "Studio/Transport.swift",
    "UI/CapLegend.swift",
    "UI/M0110Layout.swift",
]

// tools/fetch-webview2.ps1 downloads the WebView2 SDK here.
let webView2 = Context.packageDirectory + "/.deps/webview2/build/native"

let package = Package(
    name: "M0110HUD",
    targets: [
        .target(
            name: "CM0110Web",
            path: "Sources/CM0110Web",
            cxxSettings: [.unsafeFlags(["-I", webView2 + "/include"])],
            linkerSettings: [
                .linkedLibrary("advapi32"),
                .linkedLibrary("dwmapi"),
                .linkedLibrary("ole32"),
                .linkedLibrary("shcore"),
                .linkedLibrary("shell32"),
                .linkedLibrary("shlwapi"),
                .linkedLibrary("user32"),
                .linkedLibrary("version"),
                .unsafeFlags([webView2 + "/x64/WebView2LoaderStatic.lib"]),
            ]),
        .target(
            name: "CM0110Win",
            path: "Sources/CM0110Win",
            linkerSettings: [
                .linkedLibrary("advapi32"),
                .linkedLibrary("bluetoothapis"),
                .linkedLibrary("cfgmgr32"),
                .linkedLibrary("dbghelp"),
                .linkedLibrary("ole32"),
                .linkedLibrary("oleaut32"),
                .linkedLibrary("uuid"),
                .linkedLibrary("windowscodecs"),
                .linkedLibrary("gdi32"),
                .linkedLibrary("setupapi"),
                .linkedLibrary("shcore"),
                .linkedLibrary("shell32"),
                .linkedLibrary("user32"),
            ]),
        .executableTarget(
            name: "M0110HUD",
            dependencies: ["CM0110Win", "CM0110Web"],
            path: "Sources/M0110HUD",
            sources: shared + ["Windows"]),
        .testTarget(
            name: "M0110HUDTests",
            dependencies: ["M0110HUD"],
            path: "Tests/M0110HUDTests",
            sources: ["AnnouncerTests.swift", "Windows"]),
    ]
)
#else
let package = Package(
    name: "M0110HUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "M0110HUD", path: "Sources/M0110HUD", exclude: ["Windows"]),
        .testTarget(name: "M0110HUDTests", dependencies: ["M0110HUD"], path: "Tests/M0110HUDTests",
                    exclude: ["Windows"]),
    ]
)
#endif

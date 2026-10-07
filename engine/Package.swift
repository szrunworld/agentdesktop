// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentDesktopEngine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentdesktop-cli", targets: ["ScreenCLI"]),
        .executable(name: "vdisplay", targets: ["vdisplay"]),
        // Native modules embedded by the AgentDesktop product in this repository.
        .library(name: "SecondScreenCore", targets: ["SecondScreenCore"]),
        .library(name: "SecondScreenRuntime", targets: ["SecondScreenRuntime"]),
        .library(name: "TarsAgent", targets: ["TarsAgent"]),
    ],
    targets: [
        // Declarations for CoreGraphics' private CGVirtualDisplay classes.
        .target(name: "CGVirtualDisplayPrivate"),
        // Virtual display lifecycle and live preview, shared by the CLI and app.
        .target(
            name: "SecondScreenCore",
            dependencies: ["CGVirtualDisplayPrivate"]
        ),
        // The UI-TARS agent loop: prompt, model client, reply parser, and the
        // mapping from model actions to AgentDesktop input.
        .target(
            name: "TarsAgent",
            dependencies: ["SecondScreenCore"]
        ),
        // Agent screens, input into the apps on them, the agent cursor, and
        // the control socket: what a host app embeds to give agents screens.
        .target(
            name: "SecondScreenRuntime",
            dependencies: ["SecondScreenCore"]
        ),
        .executableTarget(
            name: "vdisplay",
            dependencies: ["SecondScreenCore"]
        ),
        // Agent-facing CLI; talks to the running app over a Unix socket.
        .executableTarget(
            name: "ScreenCLI",
            dependencies: ["SecondScreenCore", "TarsAgent"]
        ),
        .testTarget(
            name: "TarsAgentTests",
            dependencies: ["TarsAgent"]
        ),
        .testTarget(
            name: "SecondScreenCoreTests",
            dependencies: ["SecondScreenCore"]
        ),
        .testTarget(
            name: "SecondScreenRuntimeTests",
            dependencies: ["SecondScreenRuntime"]
        ),
    ]
)

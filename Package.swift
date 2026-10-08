// swift-tools-version:5.9
import PackageDescription

// The product and native core are maintained in this repository: the
// engine is the local package engine/ (docs/boundaries.md); there is no
// remote dependency and no Package.resolved.

let package = Package(
    name: "AgentDesktop",
    platforms: [.macOS(.v14)],
    products: [
        // The app's executable product is not "AgentDesktop": on a
        // case-insensitive volume it would be the same file as the CLI's
        // "agentdesktop" in the build directory. bundle-app.sh names the
        // binary inside the bundle.
        .executable(name: "AgentDesktopApp", targets: ["AgentDesktop"]),
        // The formal command line (CLI plan v1.2 §03); bundled at
        // Contents/Resources/bin/agentdesktop.
        .executable(name: "agentdesktop", targets: ["AgentDesktopCLI"]),
        .library(name: "AgentDesktopProtocol", targets: ["AgentDesktopProtocol"]),
        .library(name: "AgentDesktopClient", targets: ["AgentDesktopClient"]),
        .library(name: "AgentDesktopRuntime", targets: ["AgentDesktopRuntime"]),
        .library(name: "AgentDesktopAI", targets: ["AgentDesktopAI"]),
        .library(name: "AgentDesktopGUI", targets: ["AgentDesktopGUI"]),
        .library(name: "AgentDesktopService", targets: ["AgentDesktopService"]),
        .library(name: "AgentDesktopACP", targets: ["AgentDesktopACP"]),
    ],
    dependencies: [
        .package(path: "engine"),
    ],
    targets: [
        // ACP adapter (docs/acp): editors talk to the one Runtime through
        // RuntimeClient only. No GUI executor, run store or lease here.
        .target(
            name: "AgentDesktopACP",
            dependencies: ["AgentDesktopClient", "AgentDesktopProtocol", "AgentDesktopContracts"]
        ),
        .executableTarget(
            name: "agentdesktop-acp-dev",
            dependencies: ["AgentDesktopACP", "AgentDesktopClient"]
        ),
        .testTarget(
            name: "AgentDesktopACPTests",
            dependencies: ["AgentDesktopACP", "AgentDesktopClient", "AgentDesktopProtocol", "AgentDesktopContracts"],
            exclude: ["Fixtures"]
        ),

        // Menu bar host; scripts/bundle-app.sh wraps it in "Agent Desktop.app".
        .executableTarget(
            name: "AgentDesktop",
            dependencies: [
                .product(name: "SecondScreenCore", package: "engine"),
                .product(name: "SecondScreenRuntime", package: "engine"),
                "AgentDesktopRuntime",
                "AgentDesktopProtocol",
                "AgentDesktopService",
                "AgentDesktopGUI",
                "AgentDesktopAI",
                "AgentDesktopAIUI",
                "AgentDesktopUI",
            ]
        ),
        .testTarget(
            name: "AgentDesktopTests",
            dependencies: ["AgentDesktop", "AgentDesktopUI", "AgentDesktopRuntime", "AgentDesktopProtocol"]
        ),

        .testTarget(
            name: "AgentDesktopContractsTests",
            dependencies: ["AgentDesktopProtocol"],
            exclude: ["Fixtures"]
        ),
        // Dependency direction is fixed: GUI may import AI and Protocol,
        // AI only Protocol, and neither imports a Runtime or engine target.
        .target(
            name: "AgentDesktopAI",
            dependencies: ["AgentDesktopProtocol"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AgentDesktopAITests",
            dependencies: ["AgentDesktopAI", "AgentDesktopProtocol"]
        ),
        .target(
            name: "AgentDesktopGUI",
            dependencies: ["AgentDesktopProtocol", "AgentDesktopAI"]
        ),
        .testTarget(
            name: "AgentDesktopGUITests",
            dependencies: ["AgentDesktopGUI", "AgentDesktopAI", "AgentDesktopProtocol"],
            exclude: ["Fixtures"]
        ),
        // Runtime API agentdesktop.runtime/1 (CLI plan v1.2 §02, §05).
        // Dependency direction: CLI → Client → Protocol → Contracts (JSON
        // and schema primitives); Runtime → Protocol. The CLI never links
        // the Runtime, the engine or a model loop. contracts/runtime/v1 is
        // embedded as code (scripts/generate-runtime-contract.sh): binaries
        // inside the app bundle cannot locate a SwiftPM resource bundle.
        .target(
            name: "AgentDesktopProtocol"
        ),
        .target(
            name: "AgentDesktopClient",
            dependencies: ["AgentDesktopProtocol"]
        ),
        // The only execution authority. PR1 serves the read-only surface.
        // EnginePlatform drives the engine (the local engine/ package) in
        // the host process.
        .target(
            name: "AgentDesktopRuntime",
            dependencies: [
                "AgentDesktopProtocol",
                .product(name: "SecondScreenCore", package: "engine"),
                .product(name: "SecondScreenRuntime", package: "engine"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AgentDesktopCLI",
            dependencies: ["AgentDesktopClient", "AgentDesktopProtocol"]
        ),
        .testTarget(
            name: "AgentDesktopClientTests",
            dependencies: ["AgentDesktopClient", "AgentDesktopProtocol"]
        ),
        .testTarget(
            name: "AgentDesktopRuntimeTests",
            dependencies: ["AgentDesktopRuntime", "AgentDesktopClient", "AgentDesktopProtocol"]
        ),
        // The GUI service driving the Runtime's ports: explorer → Runtime
        // executor → platform, with a scripted model.
        .testTarget(
            name: "AgentDesktopIntegrationTests",
            dependencies: ["AgentDesktopRuntime", "AgentDesktopService", "AgentDesktopGUI", "AgentDesktopAI", "AgentDesktopProtocol"]
        ),
        // End-to-end tests run the CLI against a real RuntimeServer.
        .testTarget(
            name: "AgentDesktopCLITests",
            dependencies: ["AgentDesktopCLI", "AgentDesktopRuntime", "AgentDesktopClient", "AgentDesktopProtocol"]
        ),
        // Composition of contract v1 (spec §03.1): wires AI and GUI into the
        // 32 handlers. Takes input only through an injected backend.
        .target(
            name: "AgentDesktopService",
            dependencies: ["AgentDesktopProtocol", "AgentDesktopAI", "AgentDesktopGUI"]
        ),
        .testTarget(
            name: "AgentDesktopServiceTests",
            dependencies: ["AgentDesktopService", "AgentDesktopGUI", "AgentDesktopAI", "AgentDesktopProtocol", "AgentDesktopCLI",
                           "AgentDesktopRuntime"]
        ),
        // AI/GUI pages W01–W08 (spec §12): SwiftUI over a contract client;
        // knows the service only through contract v1.
        .target(
            name: "AgentDesktopAIUI",
            dependencies: ["AgentDesktopProtocol", "AgentDesktopUI"]
        ),
        // Main window shell (docs/plan/10 U1a): design tokens, components,
        // page states, navigation, the async Runtime port, a contract-only
        // Mock and the Store. Consumes runtime/1 through RuntimeAPI only;
        // it links no Runtime, engine, AI or GUI target.
        .target(
            name: "AgentDesktopUI",
            dependencies: ["AgentDesktopProtocol"]
        ),
        .testTarget(
            name: "AgentDesktopUITests",
            dependencies: ["AgentDesktopUI", "AgentDesktopProtocol"]
        ),
        .testTarget(
            name: "AgentDesktopAIUITests",
            dependencies: ["AgentDesktopAIUI", "AgentDesktopProtocol", "AgentDesktopService", "AgentDesktopAI", "AgentDesktopGUI"]
        ),
        // iPhone backends (review 2026-10-08 §6.1). WDA/: HTTP client for a
        // WebDriverAgent runner on a real iPhone; Foundation only, no engine.
        .target(
            name: "AgentDesktopIOS"
        ),
        .testTarget(
            name: "AgentDesktopIOSTests",
            dependencies: ["AgentDesktopIOS"]
        ),
    ]
)

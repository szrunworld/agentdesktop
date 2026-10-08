// swift-tools-version:5.9
import PackageDescription

// Agent Desktop: the product app. It links the 2ndscreen engine as a
// versioned dependency (docs/boundaries.md) and never carries engine code.
//
// The dependency is pinned exactly; Package.resolved records the commit.
// Moving to a new engine release means a new tag upstream, then a change
// here, never an edit inside .build/checkouts or an editable override.
let engineVersion: Version = "0.2.0"

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
        .library(name: "AgentDesktopContracts", targets: ["AgentDesktopContracts"]),
        .library(name: "AgentDesktopAI", targets: ["AgentDesktopAI"]),
        .library(name: "AgentDesktopGUI", targets: ["AgentDesktopGUI"]),
        .library(name: "AgentDesktopService", targets: ["AgentDesktopService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/szrunworld/2ndscreen.git", exact: engineVersion),
    ],
    targets: [
        // Menu bar host; scripts/bundle-app.sh wraps it in "Agent Desktop.app".
        .executableTarget(
            name: "AgentDesktop",
            dependencies: [
                .product(name: "SecondScreenCore", package: "2ndscreen"),
                .product(name: "SecondScreenRuntime", package: "2ndscreen"),
                "AgentDesktopRuntime",
                "AgentDesktopProtocol",
            ]
        ),
        .testTarget(
            name: "AgentDesktopTests",
            dependencies: ["AgentDesktop"]
        ),

        // AI/GUI contract v1 (docs/ai-gui/implementation-spec.md §03.1):
        // wire envelope, strict JSON, schema validation, operation catalog.
        // The JSON files under Resources are byte copies of
        // contracts/ai-gui/v1; ContractBundleTests keeps them equal.
        .target(
            name: "AgentDesktopContracts",
            resources: [
                .copy("Resources/domain.schema.json"),
                .copy("Resources/rpc.schema.json"),
                .copy("Resources/operations.json"),
            ]
        ),
        .testTarget(
            name: "AgentDesktopContractsTests",
            dependencies: ["AgentDesktopContracts"],
            exclude: ["Fixtures"]
        ),
        // Dependency direction is fixed: GUI may import AI and Contracts,
        // AI only Contracts, and neither imports a Runtime or engine target.
        .target(
            name: "AgentDesktopAI",
            dependencies: ["AgentDesktopContracts"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AgentDesktopAITests",
            dependencies: ["AgentDesktopAI", "AgentDesktopContracts"]
        ),
        .target(
            name: "AgentDesktopGUI",
            dependencies: ["AgentDesktopContracts", "AgentDesktopAI"]
        ),
        .testTarget(
            name: "AgentDesktopGUITests",
            dependencies: ["AgentDesktopGUI", "AgentDesktopAI", "AgentDesktopContracts"],
            exclude: ["Fixtures"]
        ),
        // Runtime API agentdesktop.runtime/1 (CLI plan v1.2 §02, §05).
        // Dependency direction: CLI → Client → Protocol → Contracts (JSON
        // and schema primitives); Runtime → Protocol. The CLI never links
        // the Runtime, the engine or a model loop. contracts/runtime/v1 is
        // embedded as code (scripts/generate-runtime-contract.sh): binaries
        // inside the app bundle cannot locate a SwiftPM resource bundle.
        .target(
            name: "AgentDesktopProtocol",
            dependencies: ["AgentDesktopContracts"]
        ),
        .target(
            name: "AgentDesktopClient",
            dependencies: ["AgentDesktopProtocol", "AgentDesktopContracts"]
        ),
        // The only execution authority. PR1 serves the read-only surface.
        // EnginePlatform drives the 2ndscreen engine in the host process
        // until its code moves into this repository (AgentDesktopCore).
        .target(
            name: "AgentDesktopRuntime",
            dependencies: [
                "AgentDesktopProtocol", "AgentDesktopContracts",
                .product(name: "SecondScreenCore", package: "2ndscreen"),
                .product(name: "SecondScreenRuntime", package: "2ndscreen"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AgentDesktopCLI",
            dependencies: ["AgentDesktopClient", "AgentDesktopProtocol", "AgentDesktopContracts"]
        ),
        .testTarget(
            name: "AgentDesktopClientTests",
            dependencies: ["AgentDesktopClient", "AgentDesktopProtocol", "AgentDesktopContracts"]
        ),
        .testTarget(
            name: "AgentDesktopRuntimeTests",
            dependencies: ["AgentDesktopRuntime", "AgentDesktopClient", "AgentDesktopProtocol", "AgentDesktopContracts"]
        ),
        // End-to-end tests run the CLI against a real RuntimeServer.
        .testTarget(
            name: "AgentDesktopCLITests",
            dependencies: ["AgentDesktopCLI", "AgentDesktopRuntime", "AgentDesktopClient",
                           "AgentDesktopProtocol", "AgentDesktopContracts"]
        ),
        // Composition of contract v1 (spec §03.1): wires AI and GUI into the
        // 32 handlers. Takes input only through an injected backend.
        .target(
            name: "AgentDesktopService",
            dependencies: ["AgentDesktopContracts", "AgentDesktopAI", "AgentDesktopGUI"]
        ),
        .testTarget(
            name: "AgentDesktopServiceTests",
            dependencies: ["AgentDesktopService", "AgentDesktopGUI", "AgentDesktopAI",
                           "AgentDesktopContracts", "AgentDesktopCLI"]
        ),
        // AI/GUI pages W01–W08 (spec §12): SwiftUI over a contract client;
        // knows the service only through contract v1.
        .target(
            name: "AgentDesktopAIUI",
            dependencies: ["AgentDesktopContracts"]
        ),
        .testTarget(
            name: "AgentDesktopAIUITests",
            dependencies: ["AgentDesktopAIUI", "AgentDesktopContracts", "AgentDesktopService",
                           "AgentDesktopAI", "AgentDesktopGUI"]
        ),
    ]
)

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
        .executable(name: "AgentDesktop", targets: ["AgentDesktop"]),
        .library(name: "AgentDesktopContracts", targets: ["AgentDesktopContracts"]),
        .library(name: "AgentDesktopAI", targets: ["AgentDesktopAI"]),
        .library(name: "AgentDesktopGUI", targets: ["AgentDesktopGUI"]),
        .executable(name: "agentdesktop-cli", targets: ["AgentDesktopCLI"]),
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
            dependencies: ["AgentDesktopContracts"]
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
            dependencies: ["AgentDesktopGUI", "AgentDesktopAI", "AgentDesktopContracts"]
        ),
        // Contract v1 client (spec §13): talks to the runtime only through
        // the local endpoint; never links an input backend.
        .executableTarget(
            name: "AgentDesktopCLI",
            dependencies: ["AgentDesktopContracts"]
        ),
        .testTarget(
            name: "AgentDesktopCLITests",
            dependencies: ["AgentDesktopCLI", "AgentDesktopContracts"]
        ),
    ]
)

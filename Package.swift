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
            dependencies: ["AgentDesktop"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

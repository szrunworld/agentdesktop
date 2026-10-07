// swift-tools-version:5.9
import PackageDescription

// The product and native core are maintained in this repository.

let package = Package(
    name: "AgentDesktop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentDesktop", targets: ["AgentDesktop"]),
    ],
    dependencies: [
        .package(path: "engine"),
    ],
    targets: [
        // Menu bar host; scripts/bundle-app.sh wraps it in "Agent Desktop.app".
        .executableTarget(
            name: "AgentDesktop",
            dependencies: [
                .product(name: "SecondScreenCore", package: "engine"),
                .product(name: "SecondScreenRuntime", package: "engine"),
            ]
        ),
        .testTarget(
            name: "AgentDesktopTests",
            dependencies: ["AgentDesktop"]
        ),
    ]
)

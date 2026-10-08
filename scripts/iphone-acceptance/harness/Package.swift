// swift-tools-version:5.9
import PackageDescription
// Acceptance-only host: serves the engine control socket ($AGENTDESKTOP_SOCKET)
// from this checkout's engine, which the product host does not open (A0).
// Never shipped; used only for real-device acceptance of engine iPhone code.
let package = Package(
    name: "harness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../engine")],
    targets: [.executableTarget(name: "harness", dependencies: [
        .product(name: "SecondScreenRuntime", package: "engine"),
    ])]
)

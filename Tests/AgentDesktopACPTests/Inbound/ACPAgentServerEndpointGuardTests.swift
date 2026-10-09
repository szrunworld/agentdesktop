import Foundation
import Testing
@testable import AgentDesktopACP

/// The dev entry's product-endpoint guard. Every case runs against a fake
/// home in a temporary directory; nothing touches the real product folder.
@Suite struct ACPAgentServerEndpointGuardTests {
    /// A fake home with the product directory created, plus a side directory.
    private func fakeHome() throws -> (root: URL, guard: ACPAgentServerEndpointGuard) {
        let root = ACPTestScratch.dir("acp-s-guard")
        let product = root.appendingPathComponent("home/Library/Application Support/AgentDesktop")
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("side"), withIntermediateDirectories: true)
        // realpath of the temporary directory (/var → /private/var) so the
        // fake home is canonical, like a real one.
        let home = ACPAgentServerEndpointGuard.resolved(root.appendingPathComponent("home").path)
        return (root, ACPAgentServerEndpointGuard(home: home, currentDirectory: root.appendingPathComponent("side").path))
    }

    @Test func everySocketInTheProductDirectoryIsRefused() throws {
        let (root, g) = try fakeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = g.productDirectory
        for name in ["control.sock", "runtime.sock", "ai.sock", "anything.sock", "acp/nested/x.sock"] {
            #expect(g.isProductPath(dir + "/" + name), "\(name)")
            #expect(g.check(dir + "/" + name, allowProduct: false) == .refusedProduct(dir + "/" + name))
            #expect(g.check(dir + "/" + name, allowProduct: true) == .allowed)
        }
        #expect(g.isProductPath(dir))
        #expect(g.isProductPath(dir + "/"))
    }

    @Test func tildeDotsAndCaseDoNotSlipThrough() throws {
        let (root, g) = try fakeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(g.isProductPath("~/Library/Application Support/AgentDesktop/control.sock"))
        #expect(g.isProductPath("~/Library/Application Support/AgentDesktop/./control.sock"))
        #expect(g.isProductPath(g.home + "/Library/Application Support/Other/../AgentDesktop/ai.sock"))
        #expect(g.isProductPath(g.home + "//Library///Application Support/AgentDesktop//runtime.sock"))
        #expect(g.isProductPath(g.home + "/library/application support/agentdesktop/control.sock"))
        // Relative to a working directory inside the home.
        let inHome = ACPAgentServerEndpointGuard(home: g.home, currentDirectory: g.home + "/Library")
        #expect(inHome.isProductPath("Application Support/AgentDesktop/control.sock"))
    }

    @Test func symlinksIntoTheProductDirectoryAreRefused() throws {
        let (root, g) = try fakeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let side = root.appendingPathComponent("side")
        // A link to the directory, a link to a socket path inside it, and a
        // link to a subdirectory reached through `..`.
        try fm.createSymbolicLink(atPath: side.appendingPathComponent("dirlink").path, withDestinationPath: g.productDirectory)
        try fm.createSymbolicLink(atPath: side.appendingPathComponent("socklink").path,
                                  withDestinationPath: g.productDirectory + "/control.sock")
        try fm.createDirectory(atPath: g.productDirectory + "/sub", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: side.appendingPathComponent("sublink").path,
                                  withDestinationPath: g.productDirectory + "/sub")
        #expect(g.isProductPath(side.appendingPathComponent("dirlink/control.sock").path))
        #expect(g.isProductPath(side.appendingPathComponent("dirlink").path + "/not-yet/x.sock"))
        #expect(g.isProductPath(side.appendingPathComponent("socklink").path)) // dangling: control.sock does not exist
        // A dangling link to a not-yet-created directory inside the product.
        try fm.createSymbolicLink(atPath: side.appendingPathComponent("futurelink").path,
                                  withDestinationPath: g.productDirectory + "/later")
        #expect(g.isProductPath(side.appendingPathComponent("futurelink").path + "/x.sock"))
        // A relative link.
        try fm.createSymbolicLink(atPath: side.appendingPathComponent("rellink").path,
                                  withDestinationPath: "../home/Library/Application Support/AgentDesktop")
        #expect(g.isProductPath(side.appendingPathComponent("rellink").path + "/ai.sock"))
        #expect(g.isProductPath(side.appendingPathComponent("sublink").path + "/../ai.sock"))
        #expect(g.isProductPath("dirlink/runtime.sock")) // relative to the side directory

        // A symlinked home is resolved too.
        let homeLink = root.appendingPathComponent("homelink")
        try fm.createSymbolicLink(atPath: homeLink.path, withDestinationPath: g.home)
        let viaLink = ACPAgentServerEndpointGuard(home: homeLink.path, currentDirectory: "/")
        #expect(viaLink.isProductPath(g.home + "/Library/Application Support/AgentDesktop/control.sock"))
    }

    @Test func sideInstancesAreAllowed() throws {
        let (root, g) = try fakeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        for p in ["/tmp/adt-acp/side.runtime.sock", root.appendingPathComponent("side/control.sock").path,
                  g.home + "/Library/Application Support/AgentDesktop2/control.sock",
                  g.home + "/Library/Application Support/AgentDesktopX.sock", g.home + "/control.sock"] {
            #expect(!g.isProductPath(p), "\(p)")
            #expect(g.check(p, allowProduct: false) == .allowed)
        }
    }

    @Test func normalization() {
        #expect(ACPAgentServerEndpointGuard.normalized("/a/./b/../c//d/") == "/a/c/d")
        #expect(ACPAgentServerEndpointGuard.normalized("/../..") == "/")
        #expect(ACPAgentServerEndpointGuard.isSameOrInside("/A/b", "/a"))
        #expect(!ACPAgentServerEndpointGuard.isSameOrInside("/ab", "/a"))
    }
}

/// The built dev binary refuses product paths before connecting.
@Suite struct ACPAgentServerDevEntryGuardTests {
    /// `.build/debug/agentdesktop-acp-dev` of this package, found from this
    /// file's path; `swift test` builds it with the other targets.
    private var binary: URL? {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() } // Inbound, AgentDesktopACPTests, Tests, file
        for sub in [".build/debug", ".build/arm64-apple-macosx/debug", ".build/x86_64-apple-macosx/debug"] {
            let c = dir.appendingPathComponent(sub).appendingPathComponent("agentdesktop-acp-dev")
            if FileManager.default.isExecutableFile(atPath: c.path) { return c }
        }
        return nil
    }

    private func run(_ args: [String], home: String) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = try #require(binary)
        p.arguments = args
        p.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let err = Pipe()
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }

    @Test func refusesEveryProductSocketWithoutConnecting() throws {
        try #require(binary != nil, "agentdesktop-acp-dev is not built under .build")
        let root = ACPTestScratch.dir("acp-s-dev")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let product = home + "/Library/Application Support/AgentDesktop"
        try FileManager.default.createDirectory(atPath: product, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: product)
        for path in [product + "/control.sock", product + "/runtime.sock", product + "/ai.sock",
                     "~/Library/Application Support/AgentDesktop/control.sock",
                     root.appendingPathComponent("link/control.sock").path] {
            let (code, text) = try run(["--endpoint", path], home: home)
            #expect(code == 2, "\(path)")
            #expect(text.contains("inside the product directory"), "\(path): \(text)")
        }
        // No option and no environment: the default is the product, refused.
        let (code, text) = try run([], home: home)
        #expect(code == 2)
        #expect(text.contains("inside the product directory"))
        // With the explicit flag the guard lets it through; nothing listens,
        // so it fails later at the socket check, still before any connect.
        let (code2, text2) = try run(["--endpoint", product + "/control.sock", "--allow-product-endpoint"], home: home)
        #expect(code2 == 2)
        #expect(!text2.contains("inside the product directory"))
        #expect(text2.contains("does not exist"))
    }
}

import Foundation
import Testing
@testable import SecondScreenCore

struct HostBundleTests {
    @Test func rawCLIUsesProductEndpointAndHonorsExplicitTestSocket() {
        let product = ControlProtocol.cliSocketURL(environment: [:])
        #expect(product.deletingLastPathComponent().lastPathComponent == "AgentDesktop")
        #expect(product.lastPathComponent == "control.sock")
        #expect(product == ControlProtocol.primarySocketURL)
        #expect(ControlProtocol.cliSocketURL(environment: ["AGENTDESKTOP_SOCKET": ""]) == product)
        #expect(ControlProtocol.cliSocketURL(environment: ["AGENTDESKTOP_SOCKET": "/tmp/agentdesktop-test.sock"]).path == "/tmp/agentdesktop-test.sock")
    }

    @Test func bundledCLICannotBorrowAnotherHostsOptionalResources() {
        let app = URL(fileURLWithPath: "/Applications/Agent Desktop.app")
        var searchedOtherHosts = false
        for relative in ["Contents/MacOS/Agent Desktop", "Contents/Resources/bin/agentdesktop", "Contents/Resources/libexec/agentdesktop-cli"] {
            let directories = HostBundle.resourceDirectories("Contents/Resources/android", containing: app.appendingPathComponent(relative)) {
                searchedOtherHosts = true
                return [URL(fileURLWithPath: "/Applications/Agent Desktop Test.app")]
            }
            #expect(directories == [app.appendingPathComponent("Contents/Resources/android")])
        }
        #expect(!searchedOtherHosts)
    }

    @Test func discoveryOnlyQueriesAgentDesktop() {
        let product = URL(fileURLWithPath: "/Applications/Agent Desktop.app")
        let other = URL(fileURLWithPath: "/Applications/Unrelated.app")
        var queried: [String] = []
        let found = HostBundle.runningAppBundles { id in
            queried.append(id)
            return id == HostBundle.applicationBundleID ? [product] : [other]
        }
        #expect(found == [product])
        #expect(queried == [HostBundle.applicationBundleID])
        queried.removeAll()
        let missing = HostBundle.runningAppBundles { id in
            queried.append(id)
            return id == HostBundle.applicationBundleID ? [] : [other]
        }
        #expect(missing.isEmpty)
        #expect(queried == [HostBundle.applicationBundleID])
    }

    @Test func optionalADBUsesItsOwningAppOrAnExplicitOverrideWithoutLaunchingTools() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Agent Desktop Resources \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let product = root.appendingPathComponent("Agent Desktop.app")
        let testCopy = root.appendingPathComponent("Agent Desktop Test.app")
        func tool(in app: URL) throws -> URL {
            let file = app.appendingPathComponent("Contents/Resources/android/adb")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file
        }
        let otherADB = try tool(in: testCopy)
        let bundledCLI = product.appendingPathComponent("Contents/Resources/libexec/agentdesktop-cli")
        #expect(ADB.executable(environment: ["PATH": ""], bundle: bundledCLI, runningApps: { [testCopy] }) == nil)
        let productADB = try tool(in: product)
        for executable in [product, bundledCLI,
                           product.appendingPathComponent("Contents/MacOS/Agent Desktop"),
                           product.appendingPathComponent("Contents/Resources/bin/agentdesktop")] {
            #expect(ADB.executable(environment: ["PATH": ""], bundle: executable, runningApps: { [testCopy] }) == productADB)
        }
        #expect(ADB.executable(environment: ["PATH": "", "ADB": otherADB.path], bundle: bundledCLI, runningApps: { [] }) == otherADB)
        #expect(ADB.executable(environment: ["PATH": ""], bundle: root.appendingPathComponent("build/agentdesktop-cli"), runningApps: { [product] }) == productADB)
        #expect(ADB.executable(environment: ["PATH": ""], bundle: nil, runningApps: { [] }) == nil)
        #expect(ADB.executable(environment: ["PATH": productADB.deletingLastPathComponent().path], bundle: nil, runningApps: { [] }) == productADB)
    }
}

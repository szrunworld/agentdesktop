import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// The file store, in temporary directories only.
@Suite struct ACPFileSessionStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acp-s-store-\(UUID().uuidString)/nested/sessions",
                                                                      isDirectory: true)
    }

    private func binding(_ id: String, principal: String = "alice", revision: Int = 1,
                         updatedAt: String = "2026-10-08T00:00:00Z") -> ACPSessionBinding {
        ACPSessionBinding(acpSessionId: id, principalId: principal, clientId: "c", cwd: "/w", title: "t",
                          runIds: ["r1"], lastCursor: ["r1": 3], options: ACPSessionManagerOptions.defaults,
                          createdAt: "2026-10-08T00:00:00Z", updatedAt: updatedAt, revision: revision)
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    @Test func roundTripAndPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = ACPFileSessionStore(directory: dir)
        #expect(try store.load(sessionId: "s1") == nil)
        #expect(try store.list(principalId: "alice").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path)) // nothing created by reads

        try store.save(binding("s1"))
        #expect(try store.load(sessionId: "s1") == binding("s1"))
        #expect(mode(dir.path) == 0o700)
        #expect(mode(dir.appendingPathComponent("s1.json").path) == 0o600)
        // No temporary files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func revisionConflicts() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = ACPFileSessionStore(directory: dir)
        #expect(throws: ACPFileSessionStoreError.conflict(sessionId: "s1", stored: 0, attempted: 2)) {
            try store.save(binding("s1", revision: 2))
        }
        try store.save(binding("s1", revision: 1))
        #expect(throws: ACPFileSessionStoreError.conflict(sessionId: "s1", stored: 1, attempted: 1)) {
            try store.save(binding("s1", revision: 1))
        }
        try store.save(binding("s1", revision: 2))
        #expect(try store.load(sessionId: "s1")?.revision == 2)
        // A second store instance (another process) sees the same revision.
        let other = ACPFileSessionStore(directory: dir)
        #expect(throws: ACPFileSessionStoreError.self) { try other.save(binding("s1", revision: 2)) }
    }

    @Test func listFiltersByPrincipalAndSkipsDamagedFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = ACPFileSessionStore(directory: dir)
        try store.save(binding("a1", updatedAt: "2026-10-08T01:00:00Z"))
        try store.save(binding("a2", updatedAt: "2026-10-08T02:00:00Z"))
        try store.save(binding("b1", principal: "bob"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        #expect(try store.list(principalId: "alice").map(\.acpSessionId) == ["a2", "a1"])
        #expect(try store.list(principalId: "bob").map(\.acpSessionId) == ["b1"])
        // A file copied onto another name is not that session.
        try FileManager.default.copyItem(at: dir.appendingPathComponent("b1.json"),
                                         to: dir.appendingPathComponent("a3.json"))
        #expect(try store.load(sessionId: "a3") == nil)
        #expect(try store.list(principalId: "bob").map(\.acpSessionId) == ["b1"])
    }

    @Test func invalidIdsAreRefused() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = ACPFileSessionStore(directory: dir)
        for bad in ["", "../x", "a/b", "a.json", String(repeating: "a", count: 129), "ä"] {
            #expect(throws: ACPFileSessionStoreError.invalidSessionId) { try store.load(sessionId: bad) }
            #expect(throws: ACPFileSessionStoreError.invalidSessionId) { try store.save(binding(bad)) }
        }
    }

    @Test func tightensAnExistingDirectory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try ACPFileSessionStore(directory: dir).save(binding("s1"))
        #expect(mode(dir.path) == 0o700)
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        // Only the path is checked; nothing is created there.
        #expect(ACPFileSessionStore.defaultDirectory().path.hasSuffix("Application Support/AgentDesktop/acp/sessions"))
    }
}

/// Catalog, input mapping, validation and keys.
@Suite struct ACPCommandCatalogTests {
    @Test func namesAreSlugsAndNeverShadowFixedCommands() {
        let c = ACPCommandCatalog(tasks: [STestHarness.task("Inspect.Window"), STestHarness.task("status"),
                                          STestHarness.task("inspect_window")])
        #expect(c.taskCommands.map(\.name) == ["inspect-window", "status-task", "inspect-window-2"])
        #expect(c.parse("/status") == .fixed(.status, argument: ""))
        #expect(c.parse("/STATUS-task x") == .task(c.tasks[1], argument: "x"))
    }

    @Test func inputMapping() throws {
        let one: JSONValue = .obj([("properties", .obj([("url", .obj([("type", .string("string"))]))]))])
        #expect(try ACPCommandInput.input(argument: "http://x", schema: one).get() == .obj([("url", .string("http://x"))]))
        #expect(try ACPCommandInput.input(argument: "", schema: one).get() == .object([]))
        #expect(try ACPCommandInput.input(argument: "{\"url\":\"u\"}", schema: one).get() == .obj([("url", .string("u"))]))
        #expect(throws: ACPCommandInput.Problem.notJSONObject) { try ACPCommandInput.input(argument: "{bad", schema: one).get() }
        let two: JSONValue = .obj([("properties", .obj([("a", .obj([("type", .string("string"))])),
                                                       ("b", .obj([("type", .string("string"))]))]))])
        #expect(throws: ACPCommandInput.Problem.self) { try ACPCommandInput.input(argument: "x", schema: two).get() }
        #expect(try ACPCommandInput.input(argument: "hi", schema: .obj([])).get() == .obj([("text", .string("hi"))]))
    }

    @Test func validatorSubset() {
        let s: JSONValue = .obj([
            ("type", .string("object")),
            ("properties", .obj([
                ("n", .obj([("type", .string("integer")), ("minimum", .int(1))])),
                ("tag", .obj([("type", .string("string")), ("enum", .array([.string("a"), .string("b")]))])),
                ("list", .obj([("type", .string("array")), ("maxItems", .int(1)), ("items", .obj([("type", .string("string"))]))])),
            ])),
            ("required", .array([.string("n")])),
            ("additionalProperties", .bool(false)),
        ])
        #expect(ACPCommandInputValidator.validate(.obj([("n", .int(2)), ("tag", .string("a"))]), schema: s).isEmpty)
        #expect(ACPCommandInputValidator.validate(.obj([("n", .int(0))]), schema: s).count == 1)
        #expect(ACPCommandInputValidator.validate(.obj([("n", .double(1.5))]), schema: s).count == 1)
        #expect(ACPCommandInputValidator.validate(.obj([("tag", .string("z"))]), schema: s).count == 2)
        #expect(ACPCommandInputValidator.validate(.obj([("n", .int(1)), ("x", .null)]), schema: s).count == 1)
        #expect(ACPCommandInputValidator.validate(.obj([("n", .int(1)), ("list", .array([.int(1), .string("s")]))]),
                                                  schema: s).count == 2)
        #expect(ACPCommandInputValidator.validate(.string("x"), schema: s).count == 1)
        // Problems never echo values.
        let p = ACPCommandInputValidator.validate(.obj([("n", .int(1)), ("tag", .string("secret-value"))]), schema: s)
        #expect(!p.joined().contains("secret-value"))
    }

    @Test func submissionKeysAreStableAndDistinct() {
        let a = ACPPromptSubmissionKey.make(sessionId: "s", ordinal: 0, taskType: "t", input: .obj([("x", .int(1))]))
        #expect(a == ACPPromptSubmissionKey.make(sessionId: "s", ordinal: 0, taskType: "t", input: .obj([("x", .int(1))])))
        #expect(a != ACPPromptSubmissionKey.make(sessionId: "s", ordinal: 1, taskType: "t", input: .obj([("x", .int(1))])))
        #expect(a != ACPPromptSubmissionKey.make(sessionId: "s2", ordinal: 0, taskType: "t", input: .obj([("x", .int(1))])))
        #expect(a.count == 5 + 32)
    }

    @Test func optionsDefaultsAndPolicy() throws {
        let d = ACPSessionManagerOptions.defaults
        #expect(ACPSessionManagerOptions.mode(d) == .ask)
        #expect(ACPSessionManagerOptions.policy(d) == ACPPrivacyPolicy())
        let all = try ACPSessionManagerOptions.setting(d, id: "screenshots", value: "all")
        #expect(ACPSessionManagerOptions.policy(all).screenshots == .all)
        // A stored value outside the choices falls back to the strict default.
        var bad = d
        bad[0].value = "yolo"
        #expect(ACPSessionManagerOptions.mode(bad) == .ask)
    }
}

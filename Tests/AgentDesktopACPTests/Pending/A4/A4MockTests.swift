import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// A4 behaviours B1–B6 (docs/acp/10-a4-identity.md §二), ACP side only.
//
// Layer: Mock. These run today against A4TestPort / A4TestRuntime. They
// prove what ACP does with identity and auth errors; they prove nothing
// about the Runtime. Passing them is not A4 acceptance — that is the job of
// the [Real·not run] tests in A4RealRuntimeTests.swift.

private func refusalCode(_ r: ACPSubmissionReceipt) -> String? {
    if case let .refused(code, _) = r { return code }
    return nil
}

private func isSessionNotFound(_ r: ACPReply?) -> Bool {
    if case let .error(e)? = r { return e.reason == "session_not_found" }
    return false
}

// MARK: B1 — an unpaired client cannot authorize anything

@Suite("A4 B1 [Mock] unpaired client cannot authorize", .tags(.a4Mock))
struct A4B1UnpairedMockTests {
    @Test("[Mock] bridge: pairing_required refuses the submission once and is never resent")
    func bridgePairingRequiredIsAFinalRefusal() async throws {
        let rt = A4TestRuntime()
        rt.credential = .unpaired
        let (port, _) = try A4Test.port(rt)
        let first = try await port.submit(A4Test.submission())
        #expect(refusalCode(first) == "pairing_required")
        #expect(rt.count("unit.run") == 1)
        // The editor retries the same prompt: answered from the log, not resent.
        let again = try await port.submit(A4Test.submission())
        #expect(refusalCode(again) == "pairing_required")
        #expect(rt.count("unit.run") == 1)
    }

    @Test("[Mock] bridge: without a Runtime-issued principal the caller is never reported verified")
    func bridgeNeverClaimsVerified() async throws {
        for credential in [A4TestRuntime.Credential.unpaired, .pairedValid] {
            let rt = A4TestRuntime()
            rt.credential = credential
            let (port, _) = try A4Test.port(rt)
            let c = try await port.caller()
            // runtime/1 has no handshake.principal yet (07 R4): placeholder only.
            #expect(c.verified == false)
            #expect(c.principalId == "local:501")
        }
    }

    @Test("[Mock] server: pairing_required ends the turn as a refusal, binds no Run, submits once")
    func serverShowsPairingRequiredAsRefusal() async throws {
        let port = A4TestPort()
        port.submitScript.with { $0 = { _ in .refused(code: "pairing_required", message: "pair this client first") } }
        let h = A4TestServer(port: port)
        defer { h.cleanup() }
        let sid = try #require(await h.newSession().sid)
        let reply = await h.prompt(sid, "do the work")
        #expect(reply == .promptFinished(.refusal))
        #expect(h.connection.allText(sid).contains("pairing_required"))
        #expect(try h.store.load(sessionId: sid)?.runIds.isEmpty == true)
        #expect(port.submitCount == 1)
    }

    @Test("[Mock] server: an unverified caller is told so; nothing claims an authenticated identity")
    func serverIsHonestAboutUnverifiedCaller() async throws {
        let h = A4TestServer()
        defer { h.cleanup() }
        let sid = try #require(await h.newSession().sid)
        #expect(await sEventually { h.connection.allText(sid).contains(ACPAgentServer.identityNoticePrefix) })
        #expect(h.connection.allText(sid).contains("尚未认证"))
        #expect(!h.connection.allText(sid).contains("已认证"))
    }
}

// MARK: B2 — clientId cannot be forged through request params

@Suite("A4 B2 [Mock] identity cannot be forged via params", .tags(.a4Mock))
struct A4B2ForgeryMockTests {
    static let identityKeys = ["clientId", "principal", "principalId", "connectionId", "credential",
                               "agentId", "trusted", "origin", "ownership", "lifetime"]

    @Test("[Mock] bridge: identity-like input keys are refused locally and nothing is sent", arguments: identityKeys)
    func bridgeRefusesIdentityKeysLocally(key: String) async throws {
        let rt = A4TestRuntime()
        let (port, _) = try A4Test.port(rt)
        let r = try await port.submit(A4Test.submission(input: A4Test.input(adding: key, .string("app:evil"))))
        #expect(refusalCode(r) != nil, "\(key) must not reach the Runtime")
        #expect(rt.count("unit.run") == 0)
    }

    @Test("[Mock] bridge: an identity key nested in the goal is not sent either")
    func bridgeRefusesNestedIdentity() async throws {
        let rt = A4TestRuntime()
        let (port, _) = try A4Test.port(rt)
        let goal = JSONValue.obj([("description", .string("x")), ("clientId", .string("app:evil"))])
        let r = try await port.submit(A4Test.submission(input: A4Test.input(adding: "goal", goal)))
        #expect(refusalCode(r) != nil)
        #expect(rt.count("unit.run") == 0)
    }

    @Test("[Mock] bridge: requestId and caller derive from the Runtime-side identity, never from input")
    func bridgeIdentityIsNotFromInput() async throws {
        let rt = A4TestRuntime()
        let (port, _) = try A4Test.port(rt)
        let before = try await port.caller()
        let key = "a4-sess/prompt-7"
        _ = try await port.submit(A4Test.submission(key))
        let sent = try #require(rt.sent("unit.run").first)
        #expect(sent.requestId == ACPSubmissionLog.requestId(principalId: "local:501", submissionKey: key))
        let keys = Set(sent.params.objectMembers?.map(\.key) ?? [])
        #expect(keys.isDisjoint(with: Set(Self.identityKeys)))
        let after = try await port.caller()
        #expect(after.principalId == before.principalId && after.clientId == before.clientId)
    }

    @Test("[Mock] server: identity strings in cwd or prompt do not change the session's principal")
    func serverIgnoresEditorSuppliedIdentity() async throws {
        let h = A4TestServer()
        defer { h.cleanup() }
        let sid = try #require(await h.newSession(cwd: "/tmp/a4?clientId=app:evil&principalId=app:evil").sid)
        _ = await h.prompt(sid, #"{"clientId":"app:evil","principalId":"app:evil","connectionId":"conn_x"}"#)
        let b = try #require(try h.store.load(sessionId: sid))
        #expect(b.principalId == "local:501")
        #expect(b.clientId == "local:501")
        #expect(try h.store.list(principalId: "app:evil").isEmpty)
    }
}

// MARK: B3 — invalid, expired or revoked credentials are refused

@Suite("A4 B3 [Mock] bad credentials are refused", .tags(.a4Mock))
struct A4B3CredentialMockTests {
    /// Existing reserved codes plus the two this workpack proposes
    /// (credential_invalid, credential_expired; 10-a4-identity.md §五).
    static let codes = ["credential_invalid", "credential_expired", "client_revoked", "pairing_required",
                        "permission_denied"]

    @Test("[Mock] bridge: a refused handshake yields no caller and is not retried", arguments: codes)
    func bridgeHandshakeRefusal(code: String) async throws {
        let rt = A4TestRuntime()
        rt.credential = .refusedAtHandshake(code: code)
        let (port, _) = try A4Test.port(rt)
        do {
            _ = try await port.caller()
            Issue.record("a caller was produced despite \(code)")
        } catch let e as ACPError {
            #expect(e.reason == code)
        }
        #expect(rt.with { rt.handshakes } == 1)
    }

    @Test("[Mock] bridge: a refused handshake refuses the submission; unit.run is never sent", arguments: codes)
    func bridgeSubmitWithBadCredential(code: String) async throws {
        let rt = A4TestRuntime()
        rt.credential = .refusedAtHandshake(code: code)
        let (port, _) = try A4Test.port(rt)
        let r = try await port.submit(A4Test.submission())
        #expect(refusalCode(r) == code)
        #expect(rt.count("unit.run") == 0)
    }

    @Test("[Mock] server: no caller → session/new fails closed, nothing is stored or submitted", arguments: codes)
    func serverFailsClosed(code: String) async throws {
        let port = A4TestPort()
        port.callerResult.with { $0 = .failure(ACPError(code: -32000, reason: code, message: A4TestSecrets.leakyMessage)) }
        let h = A4TestServer(port: port)
        defer { h.cleanup() }
        let (sid, reply) = await h.newSession()
        #expect(sid == nil)
        guard case let .error(e)? = reply else { Issue.record("expected an error, got \(String(describing: reply))"); return }
        #expect(e.reason == "caller_unavailable")
        #expect(port.submitCount == 0)
        #expect(!h.storedText().contains("acps_"))
    }
}

// MARK: B4 — no cross-client access to Runs or sessions

@Suite("A4 B4 [Mock] no cross-client access", .tags(.a4Mock))
struct A4B4IsolationMockTests {
    @Test("[Mock] bridge: another client's Run reads as not_found and ACP does not look further")
    func bridgeForeignRunIsNotFound() async throws {
        let rt = A4TestRuntime()
        rt.addForeignRun("run_foreign")
        let (port, _) = try A4Test.port(rt)
        await #expect(throws: ACPError.self) { _ = try await port.snapshot(runId: "run_foreign") }
        do { _ = try await port.snapshot(runId: "run_foreign") } catch let e as ACPError { #expect(e.reason == "not_found") }
        do { _ = try await port.cancel(runId: "run_foreign", requestId: "acp-a4-c1") } catch let e as ACPError {
            #expect(e.reason == "not_found")
        }
        #expect(rt.with { rt.runs["run_foreign"]?.phase } == "running")
        let methods = Set(rt.with { rt.calls.map(\.method) })
        #expect(methods.isSubset(of: ["run.show", "run.cancel", "runtime.status"]))
    }

    @Test("[Mock] server: another principal's session is indistinguishable from a missing one")
    func serverForeignSessionLooksMissing() async throws {
        let port = A4TestPort()
        port.runs.with { $0["run_foreign"] = ACPRunSnapshot(runId: "run_foreign", phase: "running", outcome: nil,
                                                           quiescence: "not_confirmed", lifetime: "connection_scoped") }
        let h = A4TestServer(port: port)
        defer { h.cleanup() }
        _ = try #require(await h.newSession().sid)
        let ts = "2026-10-08T00:00:00.000Z"
        try h.store.save(ACPSessionBinding(acpSessionId: "acps_foreign", principalId: "app:other", clientId: "app:other",
                                           cwd: "/tmp/a4-project", title: "theirs", runIds: ["run_foreign"],
                                           lastCursor: [:], options: ACPSessionManagerOptions.defaults,
                                           createdAt: ts, updatedAt: ts, revision: 1))

        guard case let .sessions(list)? = await h.request(.listSessions(cwd: nil)) else { Issue.record("no list"); return }
        #expect(!list.contains { $0.sessionId == "acps_foreign" })

        let loadForeign = await h.request(.resumeSession(sessionId: "acps_foreign", cwd: nil, replay: true))
        let loadMissing = await h.request(.resumeSession(sessionId: "acps_missing", cwd: nil, replay: true))
        #expect(isSessionNotFound(loadForeign))
        #expect(loadForeign == loadMissing)

        let closeForeign = await h.request(.closeSession(sessionId: "acps_foreign"))
        let closeMissing = await h.request(.closeSession(sessionId: "acps_missing"))
        #expect(isSessionNotFound(closeForeign))
        #expect(closeForeign == closeMissing)

        let promptForeign = await h.prompt("acps_foreign", "go")
        let promptMissing = await h.prompt("acps_missing", "go")
        #expect(promptForeign == promptMissing)

        // The foreign binding's Run was never read, followed or cancelled.
        #expect(!port.snapshotCalls.get().contains("run_foreign"))
        #expect(!port.eventCalls.get().contains("run_foreign"))
        #expect(port.cancels.get().isEmpty)
        #expect(port.submitCount == 0)
        #expect(try h.store.load(sessionId: "acps_foreign") != nil)
    }
}

// MARK: B5 — after revocation an existing connection submits nothing new

@Suite("A4 B5 [Mock] revocation stops new work on a live connection", .tags(.a4Mock))
struct A4B5RevocationMockTests {
    @Test("[Mock] bridge: after client_revoked no unit.run is sent and an earlier Run is not reported as fine")
    func bridgeAfterRevocation() async throws {
        let rt = A4TestRuntime()
        let (port, _) = try A4Test.port(rt)
        guard case let .accepted(run) = try await port.submit(A4Test.submission("k1")) else {
            Issue.record("first submission not accepted"); return
        }
        #expect(rt.count("unit.run") == 1)

        rt.with { rt.revoked = true }
        let second = try await port.submit(A4Test.submission("k2"))
        #expect(refusalCode(second) == "client_revoked")
        let secondAgain = try await port.submit(A4Test.submission("k2"))
        #expect(refusalCode(secondAgain) == "client_revoked")
        #expect(rt.count("unit.run") == 1)

        // A retry of the accepted submission only reads back; it cannot read,
        // so it is unconfirmed — never accepted, never resent.
        let firstAgain = try await port.submit(A4Test.submission("k1"))
        #expect(firstAgain == .unconfirmed)
        #expect(rt.count("unit.run") == 1)

        do {
            _ = try await port.snapshot(runId: run.runId)
            Issue.record("a revoked client read its Run")
        } catch let e as ACPError {
            #expect(e.reason == "client_revoked")
        }
    }

    @Test("[Mock] server: a revocation refusal is shown once and never resubmitted")
    func serverDoesNotResubmitAfterRevocation() async throws {
        let port = A4TestPort()
        let h = A4TestServer(port: port)
        defer { h.cleanup() }
        let sid = try #require(await h.newSession().sid)
        #expect(await h.prompt(sid, "first") == .promptFinished(.endTurn))
        #expect(port.submitCount == 1)

        port.submitScript.with { $0 = { _ in .refused(code: "client_revoked", message: "the client was removed") } }
        #expect(await h.prompt(sid, "second") == .promptFinished(.refusal))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(port.submitCount == 2)
        #expect(port.cancels.get().isEmpty)
        // Identity is not re-fetched to try again under another principal.
        #expect(port.callerCalls.get() == 1)
        #expect(h.connection.allText(sid).contains("client_revoked"))
    }
}

// MARK: B6 — auth failures leak no credential

@Suite("A4 B6 [Mock] auth failures leak no credential", .tags(.a4Mock))
struct A4B6LeakMockTests {
    @Test("[Mock] server: a leaky auth refusal reaches neither the editor nor the session store",
          arguments: ["client_revoked", "pairing_required", "credential_invalid", "credential_expired", "grant_missing"])
    func serverRedactsAuthRefusal(code: String) async throws {
        let port = A4TestPort()
        port.submitScript.with { $0 = { _ in .refused(code: code, message: A4TestSecrets.leakyMessage) } }
        let h = A4TestServer(port: port)
        defer { h.cleanup() }
        let sid = try #require(await h.newSession().sid)
        #expect(await h.prompt(sid, "go") == .promptFinished(.refusal))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(A4TestSecrets.leaked(in: h.editorText()).isEmpty)
        #expect(A4TestSecrets.leaked(in: h.storedText()).isEmpty)
        // Only the allowlisted code is shown (codes outside errors.json, such
        // as the proposed credential_* ones, appear as unlisted_error).
        #expect(h.connection.allText(sid).contains(ACPRedactor.errorCode(code)))
    }

    @Test("[Mock] server: a leaky caller failure is replaced by a fixed message")
    func serverCallerFailureIsFixedText() async throws {
        let port = A4TestPort()
        port.callerResult.with {
            $0 = .failure(ACPError(code: -32000, reason: "credential_invalid", message: A4TestSecrets.leakyMessage))
        }
        let h = A4TestServer(port: port)
        defer { h.cleanup() }
        _ = await h.newSession()
        #expect(A4TestSecrets.leaked(in: h.editorText()).isEmpty)
        #expect(A4TestSecrets.leaked(in: h.storedText()).isEmpty)
    }

    /// Finding F-1 (10-a4-identity.md §一.3), fixed in lane R (#132): the
    /// submission log never writes a Runtime refusal message, so a credential
    /// echoed by an auth error cannot reach submissions.json.
    @Test("[Mock] bridge: the submission log must not store a credential from an auth refusal (F-1)")
    func bridgeLogDoesNotStoreCredential() async throws {
        let rt = A4TestRuntime()
        rt.credential = .unpaired
        rt.refusalMessage = A4TestSecrets.leakyMessage
        let (port, path) = try A4Test.port(rt)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        _ = try await port.submit(A4Test.submission())
        let onDisk = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        #expect(A4TestSecrets.leaked(in: onDisk).isEmpty)
    }
}

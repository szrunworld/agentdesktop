import Foundation
import Testing
@testable import AgentDesktopAI

@Suite("File credential store (test copies)")
struct FileCredentialStoreTests {
    func dir() -> String { "/tmp/adfcs-\(UUID().uuidString.prefix(8))/credentials" }

    @Test func roundTripPermissionsAndDelete() throws {
        let path = dir()
        let s = try FileCredentialStore(directory: path)
        #expect(try s.read(credentialId: "cred_1") == nil)
        try s.write(credentialId: "cred_1", secret: "sk-canary-file")
        #expect(try s.read(credentialId: "cred_1") == "sk-canary-file")
        try s.write(credentialId: "cred_1", secret: "sk-canary-file-2")
        #expect(try s.read(credentialId: "cred_1") == "sk-canary-file-2")
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(stat(path + "/cred_1", &st) == 0 && st.st_mode & 0o777 == 0o600)
        try s.delete(credentialId: "cred_1")
        try s.delete(credentialId: "cred_1")
        #expect(try s.read(credentialId: "cred_1") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty, "no temp files left")
    }

    @Test func idsCannotLeaveTheDirectory() throws {
        let s = try FileCredentialStore(directory: dir())
        for bad in ["../x", "a/b", "", ".hidden", String(repeating: "a", count: 129), "名字"] {
            #expect(throws: CredentialStoreError.self) { try s.write(credentialId: bad, secret: "x") }
        }
    }

    // A whole configuration store over it: create, reopen, resolve.
    @Test func configStoreSurvivesARestart() async throws {
        let path = dir()
        let creds = try FileCredentialStore(directory: path)
        let digest = try ConfigStore.loadOrCreateDigestKey(in: creds)
        let db = (path as NSString).deletingLastPathComponent + "/config.sqlite"
        let store = try ConfigStore(path: db, credentials: creds, digestKey: digest)
        let conn = try await store.createConnection(name: "Ark", protocol: "openai_chat",
                                                    baseUrl: "https://ark.example.com/api/v3", timeoutMs: 30000,
                                                    apiKey: "sk-canary-restart")
        let credId = try #require(conn["credentialRef"]?.stringValue)
        let again = try FileCredentialStore(directory: path)
        #expect(try ConfigStore.loadOrCreateDigestKey(in: again) == digest)
        let reopened = try ConfigStore(path: db, credentials: again, digestKey: digest)
        #expect(try await reopened.resolveSecret(credentialId: credId) == "sk-canary-restart")
    }
}

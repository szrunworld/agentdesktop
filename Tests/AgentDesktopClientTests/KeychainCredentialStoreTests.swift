@testable import AgentDesktopClient
import Foundation
import Testing

// A4 S3: the CLI's credential lives in a keychain, never a file. This runs
// against a throwaway keychain file under /tmp, never the login keychain,
// and only when asked (AGENTDESKTOP_KEYCHAIN_TESTS=1): CI machines and a
// developer's session should not grow keychains.

private func security(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTDESKTOP_KEYCHAIN_TESTS"] == "1"))
func aCredentialRoundTripsThroughAThrowawayKeychain() throws {
    var template = Array("/tmp/adt-kc-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    let path = dir + "/test.keychain-db"
    let searchBefore = security(["list-keychains", "-d", "user"]).1
    defer {
        _ = security(["delete-keychain", path])
        try? FileManager.default.removeItem(atPath: dir)
        #expect(security(["list-keychains", "-d", "user"]).1 == searchBefore, "the user's keychain search list is untouched")
    }
    #expect(security(["create-keychain", "-p", UUID().uuidString, path]).0 == 0)
    // create-keychain may add itself to the search list; keep the user's list as it was.
    if security(["list-keychains", "-d", "user"]).1 != searchBefore {
        let before = searchBefore.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        _ = security(["list-keychains", "-d", "user", "-s"] + before)
    }
    let store = try KeychainCredentialStore(keychainPath: path)
    let endpoint = dir + "/runtime.sock"
    #expect(try store.load(endpoint: endpoint, profile: "cli") == nil)
    let first = ClientCredential(clientId: "app:one", token: "adt1_first")
    try store.save(first, endpoint: endpoint, profile: "cli")
    #expect(try store.load(endpoint: endpoint, profile: "cli") == first)
    #expect(try store.load(endpoint: endpoint, profile: "mcp") == nil, "profiles are separate")
    let second = ClientCredential(clientId: "app:two", token: "adt1_second")
    try store.save(second, endpoint: endpoint, profile: "cli")
    #expect(try store.load(endpoint: endpoint, profile: "cli") == second, "re-pairing replaces it")
    try store.delete(endpoint: endpoint, profile: "cli")
    #expect(try store.load(endpoint: endpoint, profile: "cli") == nil)
    // The token is in no file as plain text (the keychain file is encrypted).
    try store.save(first, endpoint: endpoint, profile: "cli")
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
        let bytes = FileManager.default.contents(atPath: dir + "/" + f) ?? Data()
        #expect(bytes.range(of: Data("adt1_first".utf8)) == nil, "\(f) holds the token in the clear")
    }
}

// S4: a signed release never reads an attacker-planted legacy credential
// when its provisioning/entitlement setup is absent or belongs to another team.
@Test func signedCredentialStorageRequiresItsOwnProvisionedGroup() throws {
    #expect(try KeychainCredentialStore.releaseAccessGroup(team: nil, entitlements: [:]) == nil)
    #expect(throws: (any Error).self) {
        try KeychainCredentialStore.releaseAccessGroup(team: "TEAM123456", entitlements: [:])
    }
    #expect(throws: (any Error).self) {
        try KeychainCredentialStore.releaseAccessGroup(team: "TEAM123456", entitlements: ["keychain-access-groups": ["OTHER.com.agentdesktop.client-credential"]])
    }
    #expect(try KeychainCredentialStore.releaseAccessGroup(team: "TEAM123456", entitlements: ["keychain-access-groups": ["TEAM123456.com.agentdesktop.client-credential"]]) == "TEAM123456.com.agentdesktop.client-credential")
}

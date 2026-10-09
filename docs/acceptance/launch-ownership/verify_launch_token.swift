// Real-machine verification of launch-ownership proof (L1, "launch_token_env").
//
//   swiftc -O verify_launch_token.swift -o verify && ./verify OUT.json /path/A.app [/path/B.app ...]
//
// For each app: refuse to touch it if it is already running (the user's
// instance). Otherwise read its signed identity, open it through
// LaunchServices exactly as the engine does (new instance, not activated,
// no recent item, never prompting, a one-time token in the environment),
// read the environment the kernel recorded for the returned process, then
// quit it through the handle the open returned and give the foreground
// back. Records identity, whether the token was found, and cleanup.
// For apps that are running: records only how many variables the kernel
// exposes for them (no value is read or written).
import AppKit
import Darwin
import Security

func kernelEnv(_ pid: pid_t) -> [String: String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var b = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &b, &size, nil, 0) == 0 else { return nil }
    let argc = Int(b.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    func next() -> String? {
        guard i < size else { return nil }
        let s = i
        while i < size, b[i] != 0 { i += 1 }
        defer { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }
    _ = next()
    while i < size, b[i] == 0 { i += 1 }
    for _ in 0..<argc { _ = next() }
    var e: [String: String] = [:]
    while let s = next(), !s.isEmpty { if let q = s.firstIndex(of: "=") { e[String(s[..<q])] = String(s[s.index(after: q)...]) } }
    return e
}

func identity(_ url: URL) -> [String: Any] {
    var out: [String: Any] = [:]
    let bundle = Bundle(url: url)
    out["bundleId"] = bundle?.bundleIdentifier ?? NSNull()
    out["version"] = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? NSNull()
    out["build"] = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") ?? NSNull()
    var code: SecStaticCode?
    if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code {
        out["signatureValid"] = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        var info: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let d = info as? [String: Any] {
            out["teamId"] = d[kSecCodeInfoTeamIdentifier as String] ?? NSNull()
            out["signingIdentifier"] = d[kSecCodeInfoIdentifier as String] ?? NSNull()
        }
        var req: SecRequirement?
        var text: CFString?
        if SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
           SecRequirementCopyString(req, [], &text) == errSecSuccess {
            out["designatedRequirement"] = (text as String?) ?? NSNull()
        }
    }
    return out
}

func runLoop(until done: () -> Bool, seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

var results: [[String: Any]] = []
let args = Array(CommandLine.arguments.dropFirst())
let outPath = args[0]
for path in args.dropFirst() {
    let url = URL(fileURLWithPath: path)
    var r: [String: Any] = ["app": url.lastPathComponent, "identity": identity(url)]
    let id = Bundle(url: url)?.bundleIdentifier ?? ""
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
    if !running.isEmpty {
        r["launched"] = false
        r["reason"] = "already running (the user's instance): not launched, not touched"
        r["runningInstanceEnvVarCount"] = running.map { kernelEnv($0.processIdentifier)?.count ?? -1 }
        r["result"] = "not_verified"
        results.append(r)
        continue
    }
    let front = NSWorkspace.shared.frontmostApplication
    let token = UUID().uuidString
    let c = NSWorkspace.OpenConfiguration()
    c.activates = false
    c.createsNewApplicationInstance = true
    c.addsToRecentItems = false
    c.promptsUserIfNeeded = false
    c.environment = ["AGENTDESKTOP_LAUNCH_TOKEN": token]
    var opened: NSRunningApplication?
    var openError: String?
    var finished = false
    NSWorkspace.shared.openApplication(at: url, configuration: c) { app, err in
        opened = app
        openError = err?.localizedDescription
        finished = true
    }
    runLoop(until: { finished }, seconds: 20)
    r["launched"] = opened != nil
    if let openError { r["openError"] = openError }
    guard let app = opened else { r["result"] = "open_failed"; results.append(r); continue }
    let pid = app.processIdentifier
    var env: [String: String]?
    var tries = 0
    repeat {
        env = kernelEnv(pid)
        tries += 1
        if env?["AGENTDESKTOP_LAUNCH_TOKEN"] != nil { break }
        runLoop(until: { false }, seconds: 0.3)
    } while tries < 10
    r["envVarCount"] = env?.count ?? -1
    r["tokenFound"] = env?["AGENTDESKTOP_LAUNCH_TOKEN"] == token
    r["readAttempts"] = tries
    r["newProcessesOfApp"] = NSRunningApplication.runningApplications(withBundleIdentifier: id).count
    app.terminate()
    runLoop(until: { app.isTerminated }, seconds: 3)
    if !app.isTerminated { app.forceTerminate(); runLoop(until: { app.isTerminated }, seconds: 2) }
    r["quitThroughHandle"] = app.isTerminated
    r["leftRunning"] = NSRunningApplication.runningApplications(withBundleIdentifier: id).map { Int($0.processIdentifier) }
    front?.activate()
    r["result"] = (r["tokenFound"] as? Bool) == true ? "provable" : "not_provable"
    results.append(r)
}
let record: [String: Any] = ["probe": "launch-ownership L1 (launch_token_env)",
                             "at": ISO8601DateFormatter().string(from: Date()),
                             "os": ProcessInfo.processInfo.operatingSystemVersionString,
                             "results": results]
let data = try! JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: outPath))
print(String(decoding: data, as: UTF8.self))

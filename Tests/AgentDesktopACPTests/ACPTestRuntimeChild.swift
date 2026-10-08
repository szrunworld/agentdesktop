import Darwin
import Foundation

/// A Runtime the test launches and owns (Kevin's ruling on #141, route 1):
/// its own fresh /tmp/adt-acp-* directory, its own socket, a process the
/// test spawned and alone reaps. Real-test connections are accepted only
/// when the kernel says the peer is this child (ACPTestPinnedTransport);
/// nothing an outside caller passes in (a pid, a path) can stand in for it.
///
/// Why "unreaped" matters: until this object calls waitpid(2), the child's
/// pid stays taken (alive or as a zombie), so no other process can hold it.
/// The kernel's peer audit token is built from whoever holds the pid when
/// it is asked, so its pid version adds nothing (b9, measured); the
/// transport instead requires the endpoint's socket to be held by the child
/// alone.
///
/// Test infrastructure only; not a production identity scheme.
final class ACPTestRuntimeChild: @unchecked Sendable {
    struct LaunchFailed: Error, CustomStringConvertible {
        let reason: String
        var description: String { "cannot launch the test Runtime: \(reason)" }
    }

    static let directoryPrefix = "/private/tmp/adt-acp-"

    let pid: pid_t
    /// realpath of the child's private directory.
    let directory: String
    /// Where the child's Runtime listens (`<socket>.runtime.sock`).
    let runtimeEndpoint: String

    private let lock = NSLock()
    private var reaped = false
    private var removed = false

    /// Spawn `executable` in a fresh 0700 /tmp/adt-acp-* directory with
    /// AGENTDESKTOP_SOCKET pointing into it (every other AGENTDESKTOP_*
    /// variable is dropped). `{endpoint}` in `arguments` becomes the Runtime
    /// endpoint, for stand-in children. With `waitForEndpoint`, waits until
    /// a socket exists there; the child dying first is a launch failure.
    static func launch(executable: String, arguments: [String] = [], extraEnvironment: [String: String] = [:],
                       waitForEndpoint: Bool = true, timeout: Double = 30) throws -> ACPTestRuntimeChild {
        var template = Array("/tmp/adt-acp-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw LaunchFailed(reason: "mkdtemp errno \(errno)") }
        guard let real = realpath(made, nil) else { throw LaunchFailed(reason: "realpath errno \(errno)") }
        let dir = String(cString: real)
        free(real)
        guard dir.hasPrefix(directoryPrefix), chmod(dir, 0o700) == 0 else {
            throw LaunchFailed(reason: "unexpected directory \(dir)")
        }
        let socket = dir + "/side.sock"
        let endpoint = dir + "/side.runtime.sock"

        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGENTDESKTOP_") }
        env["AGENTDESKTOP_SOCKET"] = socket
        for (k, v) in extraEnvironment { env[k] = v }
        let argv = [executable] + arguments.map { $0.replacingOccurrences(of: "{endpoint}", with: endpoint) }
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArgs + cEnv { free(p) } }

        // The test runner blocks some signals; the child must not inherit
        // that mask, or SIGTERM never reaches it.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty)
        sigfillset(&defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        // Inherit nothing but stdio: without CLOEXEC_DEFAULT the child kept
        // other tests' pipe and socket ends open (a pipe test then never saw
        // EOF, and a socket table showed extra holders).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &cArgs, &cEnv)
        guard rc == 0 else {
            rmdir(dir)
            throw LaunchFailed(reason: "posix_spawn \(String(cString: strerror(rc)))")
        }
        // The kernel must be able to name the child; otherwise fail closed.
        guard auditToken(of: pid) != nil else {
            kill(pid, SIGKILL)
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            try? FileManager.default.removeItem(atPath: dir)
            throw LaunchFailed(reason: "the kernel did not give the child's audit token (fail closed)")
        }
        let child = ACPTestRuntimeChild(pid: pid, directory: dir, endpoint: endpoint)
        if waitForEndpoint {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                var st = stat()
                if lstat(endpoint, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { break }
                guard child.isRunning else {
                    child.stop()
                    throw LaunchFailed(reason: "the child exited before listening")
                }
                guard Date() < deadline else {
                    child.stop()
                    throw LaunchFailed(reason: "no socket at \(endpoint) within \(timeout) s")
                }
                usleep(50_000)
            }
        }
        return child
    }

    private init(pid: pid_t, directory: String, endpoint: String) {
        self.pid = pid
        self.directory = directory
        self.runtimeEndpoint = endpoint
    }

    deinit { stop() }

    /// Alive and not reaped. Reaps (and remembers it) if the child exited.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return false }
        var st: Int32 = 0
        let r = waitpid(pid, &st, WNOHANG)
        if r == pid || (r < 0 && errno == ECHILD) { reaped = true; return false }
        return true
    }

    /// Whether the kernel-reported peer pid is this child. Never true once
    /// the child was reaped, since its pid may then be reused.
    func owns(peerPid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !reaped && peerPid == pid
    }

    /// Signal the child to exit and wait. With `reap: false` it stays a
    /// zombie (its pid still taken); the directory is kept either way.
    func terminate(reap: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return }
        kill(pid, SIGTERM)
        var st: Int32 = 0
        let deadline = Date().addingTimeInterval(5)
        if reap {
            while waitpid(pid, &st, WNOHANG) == 0 {
                if Date() >= deadline { kill(pid, SIGKILL); waitpid(pid, &st, 0); break }
                usleep(20_000)
            }
            reaped = true
        } else {
            // Wait for the exit without reaping: WNOWAIT leaves the zombie.
            var info = siginfo_t()
            while kill(pid, 0) == 0, waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == 0 {
                if Date() >= deadline { kill(pid, SIGKILL) }
                usleep(20_000)
            }
        }
    }

    /// Reap the child and remove its directory: only a realpath under
    /// /private/tmp/adt-acp-, never anything of the product.
    func stop() {
        terminate(reap: true)
        lock.lock(); defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        guard let r = realpath(directory, nil) else { return }
        let resolved = String(cString: r)
        free(r)
        guard resolved == directory, resolved.hasPrefix(Self.directoryPrefix) else { return }
        try? FileManager.default.removeItem(atPath: resolved)
    }

    /// The kernel's audit token for a process this user may name.
    static func auditToken(of pid: pid_t) -> audit_token_t? {
        var name = mach_port_name_t(0)
        guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, name) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, token.val.5 == UInt32(bitPattern: pid) else { return nil }
        return token
    }

    // MARK: Real-test Runtime

    /// The Runtime binary for Real tests (a built `AgentDesktopApp`), from
    /// ACP_TEST_RUNTIME_BINARY. Unset: Real tests are skipped. There is no
    /// way to point them at an already running Runtime.
    static var binary: String? {
        ProcessInfo.processInfo.environment["ACP_TEST_RUNTIME_BINARY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Launch the Real-test Runtime (fresh directory, owned by the caller).
    static func launchRuntime() throws -> ACPTestRuntimeChild {
        guard let binary else { throw LaunchFailed(reason: "set ACP_TEST_RUNTIME_BINARY to a built AgentDesktopApp") }
        guard !binary.hasPrefix("/Applications/") else { throw LaunchFailed(reason: "refusing the installed product \(binary)") }
        return try launch(executable: binary)
    }

    private static let sharedLock = NSLock()
    private static var sharedChild: ACPTestRuntimeChild?

    /// One Real-test Runtime per test process, stopped at exit.
    static func shared() throws -> ACPTestRuntimeChild {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let c = sharedChild, c.isRunning { return c }
        let c = try launchRuntime()
        if sharedChild == nil { atexit { ACPTestRuntimeChild.stopShared() } }
        sharedChild = c
        return c
    }

    private static func stopShared() {
        sharedLock.lock(); let c = sharedChild; sharedChild = nil; sharedLock.unlock()
        c?.stop()
    }
}

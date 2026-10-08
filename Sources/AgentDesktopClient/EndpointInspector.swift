import AgentDesktopProtocol
import Darwin
import Foundation
import Security

/// Read-only diagnosis of a Runtime endpoint: what is at the path, who
/// claims it, whether the one answering is that claimant, and whether its
/// services answer.
///
/// It changes nothing: no lock is taken (even a shared one could make a
/// starting Runtime give up), no file is repaired, removed or created, no
/// Runtime is started or stopped, no grant is touched, and no Run is
/// created. A connection that answers is not trusted for that alone: the
/// identity is `verified` only when the socket's peer process, the
/// handshake and the lock file's record all name the same live process;
/// otherwise it is `unverified`, or `mismatch` when they contradict.
public enum EndpointInspector {
    public enum Environment: String, Sendable {
        /// The installed product's endpoint.
        case product
        /// A side instance (AGENTDESKTOP_SOCKET), as tests and acceptance use.
        case sideInstance = "side_instance"
        case custom
    }

    public enum SocketState: String, Sendable {
        case ok, missing
        case notSocket = "not_socket"
        case otherOwner = "other_owner"
        /// Readable or writable by others than this user.
        case tooOpen = "too_open"
    }

    public enum Holder: String, Sendable {
        /// No lock file.
        case none
        /// A lock file without a readable record.
        case unknown
        /// A record from before records (a pid only).
        case legacy
        /// The recorded process is alive and started before the record.
        case alive
        /// The recorded process is gone: a leftover of a crash.
        case gone
        /// A process with that pid is alive but started after the record:
        /// the pid now belongs to someone else.
        case pidReused = "pid_reused"
    }

    public enum Identity: String, Sendable {
        case verified, unverified, mismatch
    }

    /// Whether the Runtime's process is signed by the same certificate as
    /// this program (both ship in the same app). Same-user code can write a
    /// consistent record and answer a consistent handshake; it cannot sign
    /// as the product.
    public enum Signer: String, Sendable {
        case same, different, unknown
    }

    /// Which step failed, for a caller that must decide what to do.
    public enum Failure: String, Sendable {
        case connect, identity, version, authorization, service
    }

    public struct Report: Sendable {
        public var path: String
        public var environment: Environment
        public var socket: SocketState
        public var socketMode: UInt16?
        public var directoryMode: UInt16?
        public var record: EndpointRecord?
        public var legacyPID: Int32?
        public var holder: Holder
        /// The process on the other end of the very connection the handshake
        /// used, from the kernel.
        public var peerPID: Int32?
        public var peerUID: uid_t?
        /// The pid in the audit token read after the handshake reply: the
        /// process that answered.
        public var answeringPID: Int32?
        /// Others may write the endpoint's directory: not connected.
        public var directoryUntrusted = false
        public var signer: Signer = .unknown
        /// runtime.capabilities, asked on the same connection, only of a
        /// Runtime whose identity is not contradicted.
        public var capabilities: JSONValue?
        public var connectError: String?
        public var handshake: RuntimeIdentity?
        public var handshakeError: RuntimeError?
        public var identity: Identity
        /// Why the identity is not verified; plain words, no secrets.
        public var identityNotes: [String]
        /// `run.list` answered (read only; nothing is created).
        public var runsAvailable: Bool?
        public var runsError: RuntimeError?
        public var failures: [Failure]
    }

    /// Diagnose `endpoint`; `makeClient` opens a connection for the
    /// handshake and the read-only service check.
    public static func inspect(_ endpoint: Endpoint, home: String = NSHomeDirectory(),
                               makeClient: (Endpoint) -> RuntimeClient,
                               signer: (Data) -> Signer = EndpointInspector.signer(auditToken:)) -> Report {
        let path = endpoint.path
        var report = Report(path: path, environment: environment(of: path, home: home), socket: .missing,
                            holder: .none, identity: .unverified, identityNotes: [], failures: [])

        // The directory and the socket, by stat only.
        var st = stat()
        if stat((path as NSString).deletingLastPathComponent, &st) == 0 { report.directoryMode = UInt16(st.st_mode & 0o777) }
        if lstat(path, &st) == 0 {
            report.socketMode = UInt16(st.st_mode & 0o777)
            if (st.st_mode & S_IFMT) != S_IFSOCK { report.socket = .notSocket }
            else if st.st_uid != getuid() { report.socket = .otherOwner }
            else if st.st_mode & 0o077 != 0 { report.socket = .tooOpen }
            else { report.socket = .ok }
        }

        // The lock file's record: read, never locked.
        if let text = EndpointRecord.readFile(path + ".lock") {
            let parsed = EndpointRecord.parse(text)
            report.record = parsed.record
            report.legacyPID = parsed.legacyPID
            if let r = parsed.record {
                report.holder = holder(pid: r.pid, recordedSince: Timestamp.date(r.since))
            } else if let pid = parsed.legacyPID {
                report.holder = processStart(pid) == nil ? .gone : .legacy
            } else {
                report.holder = .unknown
            }
        } else if FileManager.default.fileExists(atPath: path + ".lock") {
            report.holder = .unknown
        }

        // A directory others may write: whoever can replace the socket there
        // is not to be talked to, so nothing is sent.
        if report.socket == .ok, let mode = report.directoryMode, mode & 0o022 != 0 {
            report.failures.append(.connect)
            report.identityNotes.append("others may write the endpoint's directory; not connected")
            report.directoryUntrusted = true
            return report
        }
        guard report.socket == .ok else {
            report.failures.append(.connect)
            report.identityNotes.append("nothing that may be trusted listens at the path (\(report.socket.rawValue))")
            return report
        }

        let client = makeClient(endpoint)
        defer { client.close() }
        do {
            report.handshake = try client.handshake()
        } catch let e as RuntimeError {
            report.handshakeError = e
            if e.phase == .connect || e.code == "runtime_offline" { report.connectError = e.message }
            report.failures.append(e.code == "version_mismatch" ? .version : (report.connectError != nil ? .connect : .identity))
            report.identityNotes.append(report.connectError != nil ? "the socket does not accept connections" : "no handshake")
            return report
        } catch {
            report.handshakeError = RuntimeError("internal_error", "\(error)", phase: .handshake)
            report.failures.append(.identity)
            return report
        }
        // The peer of this very connection (a client without one, as in
        // tests, is asked on a probe connection that sends nothing).
        if let peer = client.peer {
            report.peerPID = peer.pid
            report.peerUID = peer.uid
        } else if case let .success(pid) = peerPID(path) {
            report.peerPID = pid
        }
        // The signature of the process that wrote the handshake reply, by its
        // audit token read after the reply: a pid alone could since belong
        // to a binary exec'd in its place, the token's exec generation not.
        // Without a token the signer stays unknown.
        if let token = client.peerAuditToken() {
            report.answeringPID = auditTokenPID(token)
            report.signer = signer(token)
        }

        (report.identity, report.identityNotes) = judge(report)
        // A contradicted identity is not asked anything more: what it would
        // answer (permissions, Runs) is not to be shown as fact.
        guard report.identity != .mismatch else {
            report.failures.append(.identity)
            return report
        }
        if report.identity != .verified { report.failures.append(.identity) }

        do {
            report.capabilities = try client.call(RuntimeRequest(.capabilities))
        } catch {}
        do {
            _ = try client.call(RuntimeRequest(.runList, params: .obj([("limit", .int(1))])))
            report.runsAvailable = true
        } catch let e as RuntimeError {
            report.runsAvailable = false
            report.runsError = e
            if e.code != "capability_missing" {
                report.failures.append(Self.authorizationCodes.contains(e.code) ? .authorization : .service)
            }
        } catch {
            report.runsAvailable = false
            report.failures.append(.service)
        }
        return report
    }

    static let authorizationCodes: Set<String> = [
        "permission_denied", "pairing_required", "client_revoked", "grant_missing", "grant_expired",
    ]

    public static func environment(of path: String, home: String) -> Environment {
        let productDir = (EndpointResolver.productEndpoint(home: home) as NSString).deletingLastPathComponent
        if (path as NSString).deletingLastPathComponent == productDir { return .product }
        return path.hasSuffix(".runtime.sock") ? .sideInstance : .custom
    }

    /// Whether the handshake, the peer and the record name the same process.
    static func judge(_ r: Report) -> (Identity, [String]) {
        guard let id = r.handshake else { return (.unverified, ["no handshake"]) }
        var notes: [String] = []
        var contradiction = false
        if id.product != "AgentDesktop" { notes.append("the handshake names product \(id.product)"); contradiction = true }
        if id.endpoint != r.path { notes.append("the Runtime says it serves another path"); contradiction = true }
        if let peer = r.peerPID {
            if peer != id.pid { notes.append("the socket's peer is pid \(peer), the handshake says \(id.pid)"); contradiction = true }
        } else {
            notes.append("the socket's peer process is unknown")
        }
        if let answering = r.answeringPID, answering != id.pid {
            notes.append("pid \(answering) answered, the handshake says \(id.pid)"); contradiction = true
        }
        if let uid = r.peerUID, uid != getuid() { notes.append("the socket's peer runs as another user"); contradiction = true }
        switch r.signer {
        case .same: break
        case .different: notes.append("the Runtime's process is not signed as this product"); contradiction = true
        case .unknown: notes.append("the Runtime's code signature cannot be compared with this program's")
        }
        if let rec = r.record {
            if rec.pid != id.pid || rec.instanceId != id.instanceId {
                notes.append("the lock file names another instance"); contradiction = true
            }
            if !rec.listening { notes.append("the lock file's record does not say it listens") }
            if r.holder != .alive { notes.append("the recorded process is \(r.holder.rawValue)") }
        } else {
            notes.append(r.legacyPID != nil ? "the lock file holds only a pid" : "no ownership record")
        }
        if contradiction { return (.mismatch, notes) }
        return (notes.isEmpty ? .verified : .unverified, notes)
    }

    static func holder(pid: Int32, recordedSince: Date?) -> Holder {
        guard let started = processStart(pid) else { return .gone }
        guard let since = recordedSince else { return .unknown }
        // The owner wrote its record after it started; a process that started
        // after the record cannot be that owner.
        return started <= since.addingTimeInterval(1) ? .alive : .pidReused
    }

    /// The kernel's start time of a live process; nil when there is none.
    static func processStart(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// Connect, ask the kernel who is on the other end, close without
    /// sending a byte.
    struct ProbeFailure: Error { let message: String }

    static func peerPID(_ path: String) -> Result<Int32, ProbeFailure> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(ProbeFailure(message: String(cString: strerror(errno)))) }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .failure(ProbeFailure(message: "the path is too long for a socket")) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(ProbeFailure(message: String(cString: strerror(errno)))) }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else {
            return .failure(ProbeFailure(message: String(cString: strerror(errno))))
        }
        return .success(pid)
    }

    /// The pid in an audit token (its sixth word), nil if malformed.
    public static func auditTokenPID(_ token: Data) -> Int32? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        return token.withUnsafeBytes { Int32(bitPattern: $0.load(fromByteOffset: 5 * 4, as: UInt32.self)) }
    }

    /// Compare the leaf signing certificate of the process named by an audit
    /// token with this program's. The token holds the process's exec
    /// generation: a process that exec'd since is not found (`unknown`).
    /// Unsigned or ad-hoc code on either side is `unknown`.
    public static func signer(auditToken: Data) -> Signer {
        func leaf(_ code: SecCode) -> Data? {
            guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let dict = info as? [String: Any],
                  let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certs.first
            else { return nil }
            return SecCertificateCopyData(first) as Data
        }
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, let mine = leaf(me) else { return .unknown }
        var peer: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken as CFData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess, let peer else { return .unknown }
        guard let theirs = leaf(peer) else { return .different }
        return theirs == mine ? .same : .different
    }
}

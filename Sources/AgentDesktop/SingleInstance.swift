import AgentDesktopProtocol
import AppKit
import Foundation

/// One Agent Desktop process at a time for the user, the product and test
/// copies alike (Kevin, 2026-10-11). Ownership is an exclusive flock on
/// `instance.lock` beside the product endpoint, taken before anything else
/// starts and held until the process ends; the kernel drops it when the
/// process dies, so a crash leaves nothing to clean up. The file names the
/// holder, for the message a refused launch shows.
enum SingleInstance {
    struct Holder: Codable, Equatable {
        var pid: Int32
        /// "product" or "test".
        var role: String
        var bundlePath: String
    }

    enum Outcome: Equatable {
        /// This process holds the lock; keep the descriptor open.
        case acquired(fd: Int32)
        /// Another process holds it (nil when its record is unreadable).
        case held(Holder?)
        case failed(String)
    }

    /// `~/Library/Application Support/AgentDesktop/instance.lock`.
    static var lockPath: String {
        HostRole.productEndpoint.deletingLastPathComponent().appendingPathComponent("instance.lock").path
    }

    static func acquire(at path: String, as me: Holder) -> Outcome {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("cannot create \(dir): \(error)")
        }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed("open \(path): \(String(cString: strerror(errno)))") }
        var st = stat()
        // One link only: a hard link to another file would have it rewritten.
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else {
            close(fd)
            return .failed("\(path) is not a file of this user")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let holder = read(fd)
            close(fd)
            return .held(holder)
        }
        fchmod(fd, 0o600)
        if let data = try? JSONEncoder().encode(me) {
            ftruncate(fd, 0)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) }
        }
        return .acquired(fd: fd)
    }

    private static func read(_ fd: Int32) -> Holder? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = pread(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: Data(buffer[0..<n]))
    }

    /// A build from before this lock holds none. Two ways to see one that
    /// is running: any other process of this bundle, launched even if its
    /// Runtime does not listen yet (a test copy too); and the product's
    /// Runtime endpoint, whose record (`runtime.sock.lock`, JSON or a bare
    /// pid) names the process to bring forward.
    struct RunningApp: Equatable {
        var pid: Int32
        var bundlePath: String?
        /// A Dock app right now. A product kept in the background is
        /// accessory too, so this only decides when the product's Runtime
        /// record names no process.
        var regular: Bool
    }

    /// Another running process of this bundle. It is the product when the
    /// product's Runtime record names its pid (`productPID`), whatever its
    /// activation policy.
    static func otherRunning(me: Int32 = getpid(), productPID: Int32? = productRecordPID(), apps: () -> [RunningApp] = {
        NSRunningApplication.runningApplications(withBundleIdentifier: HostRole.bundleID)
            .filter { !$0.isTerminated }
            .map { RunningApp(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path, regular: $0.activationPolicy == .regular) }
    }) -> Holder? {
        let others = apps().filter { $0.pid != me }
        guard let other = others.first(where: { $0.pid == productPID }) ?? others.first else { return nil }
        let product = productPID.map { $0 == other.pid } ?? other.regular
        return Holder(pid: other.pid, role: product ? "product" : "test", bundlePath: other.bundlePath ?? "")
    }

    /// The pid the product's Runtime endpoint record names (JSON or a bare
    /// pid), if any.
    static func productRecordPID(endpointRecord: String = HostRole.product.runtimeEndpoint.path + ".lock") -> Int32? {
        guard let text = EndpointRecord.readFile(endpointRecord) else { return nil }
        let parsed = EndpointRecord.parse(text)
        return (parsed.record?.pid ?? parsed.legacyPID).flatMap { $0 > 0 ? $0 : nil }
    }

    static func legacyProduct(endpointRecord: String = HostRole.product.runtimeEndpoint.path + ".lock",
                              bundleOf: (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path }) -> Holder? {
        guard let pid = productRecordPID(endpointRecord: endpointRecord), let bundle = bundleOf(pid) else { return nil }
        return Holder(pid: pid, role: "product", bundlePath: bundle)
    }

    /// What a refused launch says.
    static func refusal(_ holder: Holder?) -> String {
        let running: String
        if let holder {
            let what = holder.role == "test" ? "测试副本" : " Agent Desktop "
            running = "已经有一个\(what)在运行（pid \(holder.pid)，\(holder.bundlePath)）。"
        } else {
            running = "已经有一个 Agent Desktop 在运行。"
        }
        return running + "同一时间只能运行一个，这次启动将退出。"
    }

    /// The button of the refusal alert; pressing it quits this launch.
    static let confirmTitle = "确定退出"

    /// A refused launch. The product says so in an alert and quits only
    /// once the user confirms; if a product is the one running, it then
    /// comes forward with its main window. A test copy, started by a
    /// script, says so on standard error.
    @MainActor
    static func refuse(role: HostRole, holder: Holder?) -> Never {
        let message = refusal(holder)
        guard case .product = role else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(HostRole.productName) 已在运行"
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        // macOS may refuse the activation while the user is in another app;
        // the alert then sat behind that app's windows and the launch
        // seemed to do nothing (2026-10-12 on the machine). Above normal
        // windows it is seen either way.
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
        alert.runModal()
        if let holder, holder.role == "product", !holder.bundlePath.isEmpty {
            // Reopen, not just activate: the running one shows its main
            // window even if it was kept in the background.
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: holder.bundlePath),
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 5)
        }
        exit(0)
    }
}

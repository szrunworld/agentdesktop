import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
@testable import AgentDesktopRuntime

struct FixedBackend: RuntimeBackend {
    var perms = BackendPermissions(screenRecording: .granted, accessibility: .granted)
    var apps: [AppSummary] = [
        AppSummary(process: ProcessIdentity(pid: 101, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: "com.apple.calculator",
                   name: "Calculator", active: false, hidden: false),
    ]
    var wins: [WindowSummary] = [
        WindowSummary(windowId: 11, process: ProcessIdentity(pid: 101, startedAt: "2026-10-08T01:00:00.000Z"),
                      appName: "Calculator", bundleId: "com.apple.calculator", title: "Calculator",
                      frame: Rect(x: 10, y: 20, width: 230, height: 400), onScreen: true),
        WindowSummary(windowId: 12, process: ProcessIdentity(pid: 202, startedAt: nil), appName: "微信",
                      bundleId: "com.tencent.xinWeChat", title: "文件传输助手 \"草稿\"\n第二行",
                      frame: Rect(x: -1440, y: 0, width: 800, height: 600), onScreen: true),
        WindowSummary(windowId: 13, process: ProcessIdentity(pid: 202, startedAt: nil), appName: "微信",
                      bundleId: "com.tencent.xinWeChat", title: "最小化的窗口",
                      frame: Rect(x: 0, y: 0, width: 400, height: 300), onScreen: false),
    ]

    var platform: Platform { Platform(os: "macos", osVersion: "15.1.0", arch: "arm64") }
    func permissions() -> BackendPermissions { perms }
    func features() -> [String] { ["apps.list", "windows.list"] }
    func applications(includeBackground: Bool) -> [AppSummary] { apps }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        wins.filter { (pid == nil || $0.process.pid == pid) && (bundleId == nil || $0.bundleId == bundleId)
            && (includeOffscreen || $0.onScreen) }
    }
}

func makeService(backend: RuntimeBackend = FixedBackend(), endpoint: String = "/tmp/t.sock",
                 desktops: DesktopRegistry = DesktopRegistry()) -> RuntimeService {
    RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(),
                                             startedAt: Timestamp.string(Date()), endpoint: endpoint,
                                             buildSource: "unknown"),
                   backend: backend, desktops: desktops)
}

/// A short private directory for sockets (sun_path holds 104 bytes).
func socketDirectory() throws -> String {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    guard let p = mkdtemp(&template) else { throw POSIXError(.EIO) }
    return String(cString: p)
}

/// A raw connection that speaks lines, for tests below the client.
final class RawConnection {
    let fd: Int32
    let channel: LineChannel

    init(_ path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = SocketOptions.noSigPipe(fd)
        var addr = SocketOptions.address(path)!
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.fd = fd
        SocketOptions.receiveTimeout(fd, seconds: 5)
        channel = LineChannel(fd: fd, limit: 4 * RuntimeAPI.maxFrameBytes)
    }

    func send(_ text: String) { _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }

    func read() throws -> JSONValue {
        guard case let .line(d) = channel.readLine() else { throw POSIXError(.ECONNRESET) }
        return try StrictJSON.parse(d)
    }

    deinit { close(fd) }
}

let handshakeLine = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"hs_1","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}}"#

func requestLine(_ method: String, id: String = "req_1", params: String = "{}") -> String {
    #"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(id)","method":"\#(method)","params":\#(params)}"#
}

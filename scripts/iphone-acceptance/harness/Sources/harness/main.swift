import AppKit
import SecondScreenRuntime

let path = ProcessInfo.processInfo.environment["AGENTDESKTOP_SOCKET"]!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runtime = MainActor.assumeIsolated { AgentRuntime(serialBase: 960) }
MainActor.assumeIsolated {
    do { try runtime.start(socketPath: path) } catch { print("start failed: \(error)"); exit(1) }
}
print("serving \(path)")
app.run()

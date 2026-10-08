import AppKit
import SecondScreenCore

// A client that connects and leaves before sending a request (the listener
// check below, for one) makes the engine's ControlServer write its error
// reply to a closed socket. Without this the kernel's SIGPIPE would end the
// host; with it the write fails quietly, which the server already tolerates.
signal(SIGPIPE, SIG_IGN)

let role = HostRole.current

// One product host only: a second would try to create the same virtual
// display (macOS refuses a duplicate) and add a second preview. Side
// instances keep to the background on their own sockets and do not count.
// (A listener check, not atomic ownership; the Runtime server's lock file
// is the atomic one.) The Runtime endpoint is the host's only listener.
if case .product = role, ControlProtocol.isListening(role.runtimeEndpoint) {
    exit(0)
}

// Menu bar only for now: no Dock icon, no main window. The product's main
// window and Dock entry come with the task workspace (roadmap F04).
// Top-level code runs on the main thread, so it may assume main-actor isolation.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController(role: role)
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}

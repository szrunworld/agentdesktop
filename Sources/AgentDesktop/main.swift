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

// The product has a Dock icon and the one main window; a test copy keeps to
// the background. Top-level code runs on the main thread, so it may assume
// main-actor isolation.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController(role: role)
    app.delegate = controller
    app.setActivationPolicy(role.activationPolicy)
    app.run()
}

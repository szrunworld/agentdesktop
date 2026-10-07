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
// (A listener check, not atomic ownership; see HostRole.)
if case .product = role, ControlProtocol.isListening(role.endpoint) {
    exit(0)
}

// The product has a Dock entry and a main window; a side instance keeps to
// the background with neither. Top-level code runs on the main thread, so
// it may assume main-actor isolation.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController(role: role)
    app.delegate = controller
    app.setActivationPolicy(role.isSideInstance ? .accessory : .regular)
    app.run()
}

import AppKit
import SecondScreenCore

// A client that connects and leaves before sending a request (the listener
// check below, for one) makes the engine's ControlServer write its error
// reply to a closed socket. Without this the kernel's SIGPIPE would end the
// host; with it the write fails quietly, which the server already tolerates.
signal(SIGPIPE, SIG_IGN)

let role = HostRole.current

// One Agent Desktop process at a time, the product and test copies alike
// (SingleInstance), decided before anything starts. The lock's descriptor
// stays open for the life of the process.
let instanceLock: Int32 = MainActor.assumeIsolated {
    let me = SingleInstance.Holder(pid: getpid(), role: role.isSideInstance ? "test" : "product",
                                   bundlePath: Bundle.main.bundlePath)
    switch SingleInstance.acquire(at: SingleInstance.lockPath, as: me) {
    case .acquired(let fd):
        // A build from before the lock holds none: its Runtime endpoint
        // still tells it is there.
        if ControlProtocol.isListening(HostRole.product.runtimeEndpoint) {
            SingleInstance.refuse(role: role, holder: SingleInstance.legacyProduct())
        }
        return fd
    case .held(let holder):
        SingleInstance.refuse(role: role, holder: holder)
    case .failed(let why):
        FileHandle.standardError.write(Data("\(HostRole.productName) cannot start: \(why)\n".utf8))
        exit(1)
    }
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

// Neutral probe for UI acceptance (no user data, no network). One window
// with a text field; every key it receives is appended to the log. The
// window is created directly at the global top-left point given in
// /tmp/adt-u2a/probe-target.json ({"x":..,"y":..}) so it never opens on the
// user's displays; without that file it quits instead of showing anything.
import AppKit

let log = URL(fileURLWithPath: "/tmp/adt-u2a/probe.log")
func note(_ s: String) {
    let line = "\(Date().timeIntervalSince1970) pid \(getpid()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: log, atomically: true, encoding: .utf8) }
}

final class KeyField: NSTextField {
    override func keyUp(with event: NSEvent) { note("key \(event.characters ?? "?")"); super.keyUp(with: event) }
}

guard let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/adt-u2a/probe-target.json")),
      let t = try? JSONSerialization.jsonObject(with: data) as? [String: Double], let gx = t["x"], let gy = t["y"] else {
    note("no target file; quitting without a window")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mainHeight = NSScreen.screens.first!.frame.height    // global top-left → Cocoa bottom-left
let size = NSSize(width: 400, height: 300)
let rect = NSRect(x: gx + 40, y: mainHeight - gy - 40 - size.height, width: size.width, height: size.height)
// Show nothing unless the window lies wholly on the named (virtual) display.
let target = UInt32(t["display"] ?? -1)
guard let screen = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target
}), screen.frame.contains(rect) else {
    note("target display \(target) missing or window would leave it; quitting without a window")
    exit(3)
}
let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
w.title = "Probe A"
let field = KeyField(frame: NSRect(x: 20, y: 200, width: 360, height: 28))
field.placeholderString = "探针输入框"
let label = NSTextField(labelWithString: "中立探针 · 只记录收到的按键")
label.frame = NSRect(x: 20, y: 150, width: 360, height: 24)
w.contentView?.addSubview(field)
w.contentView?.addSubview(label)
w.setFrameOrigin(rect.origin)
w.orderFrontRegardless()
note("window \(w.windowNumber) at global (\(gx + 40), \(gy + 40))")
app.run()

import AppKit
// Logs pointer and frontmost app every 20 ms, one line per change, until killed.
setvbuf(stdout, nil, _IOLBF, 0)
var last = ""
let f = ISO8601DateFormatter(); f.formatOptions = [.withTime, .withFractionalSeconds]
while true {
    let p = CGEvent(source: nil)!.location
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let s = "(\(Int(p.x)),\(Int(p.y))) front=\(front)"
    if s != last { print("\(f.string(from: Date())) \(s)"); last = s }
    Thread.sleep(forTimeInterval: 0.02)
}

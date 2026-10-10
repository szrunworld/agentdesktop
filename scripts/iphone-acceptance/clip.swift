import AppKit
import CryptoKit
// clip set text|rtf|image|file   — put a known test item on the general pasteboard
// clip dump                       — print every item's types with a SHA-256 of each
var args = Array(CommandLine.arguments.dropFirst())
var pb = NSPasteboard.general
if args.first == "--pasteboard" {
    guard args.count >= 3 else { fatalError("usage: clip [--pasteboard NAME] set TYPE|dump") }
    pb = NSPasteboard(name: NSPasteboard.Name(args[1]))
    args.removeFirst(2)
}
guard args == ["dump"] || (args.count == 2 && args[0] == "set" && ["text", "rtf", "image", "file"].contains(args[1])) else {
    fatalError("usage: clip [--pasteboard NAME] set text|rtf|image|file|dump")
}
func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(12).description }
switch args[0] {
case "set":
    pb.clearContents()
    switch args[1] {
    case "text": pb.setString("KEEP-TEXT-原始剪贴板-1", forType: .string)
    case "rtf":
        let a = NSAttributedString(string: "KEEP-RTF 富文本", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        pb.writeObjects([a])
    case "image":
        let img = NSImage(size: NSSize(width: 32, height: 32)); img.lockFocus(); NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill(); img.unlockFocus(); pb.writeObjects([img])
    case "file":
        let u = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("clip-file.txt")
        try! "file item".write(to: u, atomically: true, encoding: .utf8); pb.writeObjects([u as NSURL])
    default: fatalError()
    }
case "dump":
    for (i, item) in (pb.pasteboardItems ?? []).enumerated() {
        for t in item.types.sorted(by: { $0.rawValue < $1.rawValue }) {
            print("\(i) \(t.rawValue) \(item.data(forType: t).map(sha) ?? "nil")")
        }
    }
default: fatalError()
}

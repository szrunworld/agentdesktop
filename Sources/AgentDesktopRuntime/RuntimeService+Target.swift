import AgentDesktopProtocol
import Foundation

/// G0 (MAC-001): the window an observation shows, the window whose
/// elements were read and the window input reaches must be the same bound
/// window. Window identity is the Runtime's (windowId + process launch +
/// Desktop + binding generation), never a title or a pid alone. Until
/// per-window capture and delivery exist this is conservative: whenever
/// another window could be seen or reached instead, nothing is observed or
/// sent.
extension RuntimeService {
    /// Windows in front of the bound window that it must not share with.
    /// Throws stale_observation (with `details.reason`) when the bound
    /// window is not exposed; returns the window and a fingerprint of the
    /// stack to compare after a capture.
    func exposedTarget(_ d: DesktopRecord, _ b: TargetBinding, notSent: Bool) throws
        -> (window: PlatformWindow, stack: [StackEntry]) {
        guard let platform else { throw RuntimeError.capabilityMissing("no desktop platform") }
        func refuse(_ reason: String, _ message: String, covering: PlatformWindow? = nil) -> RuntimeError {
            var details: [(String, JSONValue)] = [("reason", .string(reason)), ("generation", .int(b.generation)),
                                                  ("windowId", .int(Int(b.windowId)))]
            if let covering {
                details += [("coveringWindowId", .int(Int(covering.windowId)))]
            }
            return RuntimeError("stale_observation", message, phase: .handler, notSent: notSent, details: .obj(details))
        }
        guard let window = platform.window(on: d.screen, pid: b.process.pid, windowId: b.windowId) else {
            throw refuse("window_gone", "window \(b.windowId) is no longer on desktop \(d.desktopId); bind a window again")
        }
        let stack = platform.stack(on: d.screen)
        guard let index = stack.firstIndex(where: { $0.windowId == b.windowId }) else {
            throw refuse("not_visible", "window \(b.windowId) is not visible on desktop \(d.desktopId)")
        }
        let front = stack[..<index]
        if let cover = front.first(where: { Self.overlap($0.frame, window.frame) }) {
            throw refuse("occluded",
                         "window \(cover.windowId) covers the bound window \(b.windowId); bind the window you mean, or move it away",
                         covering: cover)
        }
        // Keys go to the app's frontmost window, not to a window id: another
        // window of the process in front would receive them (Safari opening
        // a new window). A new window never inherits the binding.
        let ownFront = backend.windows(pid: b.process.pid, bundleId: nil, includeOffscreen: false)
            .filter { $0.frame.width >= 2 && $0.frame.height >= 2 }
        if let first = ownFront.first, first.windowId != b.windowId {
            let sibling = PlatformWindow(windowId: first.windowId, pid: b.process.pid, appName: first.appName,
                                         title: first.title ?? "", frame: first.frame)
            throw refuse("other_window_of_process_in_front",
                         "window \(first.windowId) of the same app is in front of the bound window \(b.windowId); bind it explicitly to use it",
                         covering: sibling)
        }
        // The fingerprint compared around a capture: the windows that share
        // the bound window's area. Elsewhere on the screen things may come
        // and go (the screen-recording indicator in the menu bar does on
        // every capture) without changing what was captured.
        return (window, stack.filter { $0.windowId == b.windowId || Self.overlap($0.frame, window.frame) }
            .map { StackEntry(windowId: $0.windowId, frame: $0.frame) })
    }

    struct StackEntry: Equatable {
        let windowId: UInt32
        let frame: AgentDesktopProtocol.Rect
    }

    /// Overlap of more than a sliver: shadows and 1 pt borders do not count.
    static func overlap(_ a: AgentDesktopProtocol.Rect, _ b: AgentDesktopProtocol.Rect) -> Bool {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return w > 1 && h > 1
    }
}

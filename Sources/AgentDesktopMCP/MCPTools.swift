import AgentDesktopProtocol
import Foundation

/// The MCP tools: each one maps to one runtime/1 method. Descriptions are
/// what a model reads to decide how to call them.
enum MCPTools {
    struct Tool {
        let name: String
        let description: String
        let schema: JSONValue
        let method: RuntimeMethod
        let mutation: Bool
    }

    static func object(_ props: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        var m: [(String, JSONValue)] = [("type", .string("object")), ("properties", .obj(props)),
                                        ("additionalProperties", .bool(false))]
        if !required.isEmpty { m.append(("required", .array(required.map(JSONValue.string)))) }
        return .obj(m)
    }

    static func str(_ d: String) -> JSONValue { .obj([("type", .string("string")), ("description", .string(d))]) }
    static func int(_ d: String) -> JSONValue { .obj([("type", .string("integer")), ("description", .string(d))]) }
    static func num(_ d: String) -> JSONValue { .obj([("type", .string("number")), ("description", .string(d))]) }
    static func bool(_ d: String) -> JSONValue { .obj([("type", .string("boolean")), ("description", .string(d))]) }

    static let requestId: (String, JSONValue) = ("requestId", str("Optional. Reuse the same value only to retry the very same write after an unclear failure; the Runtime then returns the original outcome instead of acting twice."))
    static let session: (String, JSONValue) = ("sessionId", str("Session from session_open."))
    static let snapshot: (String, JSONValue) = ("snapshotId", str("Snapshot from the latest observe of this session. Element refs and image points are only valid with it."))
    static let element: (String, JSONValue) = ("elementRef", str("Element id from that snapshot, e.g. el_7."))
    static let x: (String, JSONValue) = ("x", num("X in the image returned by observe (its pixels), instead of elementRef."))
    static let y: (String, JSONValue) = ("y", num("Y in the image returned by observe."))

    static let all: [Tool] = [
        Tool(name: "runtime_status", description: "Identity and state of the AgentDesktop Runtime.",
             schema: object([]), method: .status, mutation: false),
        Tool(name: "desktop_list", description: "Desktops (private virtual screens for agents) this Runtime manages.",
             schema: object([]), method: .desktopList, mutation: false),
        Tool(name: "desktop_create", description: "Create a Desktop: a private virtual screen the user does not see or use. Apps placed there run in the background of the user's own work.",
             schema: object([("name", str("Optional unique name.")), ("width", int("Points, 320-6016; with height.")),
                             ("height", int("Points, 240-3384; with width.")), requestId]),
             method: .desktopCreate, mutation: true),
        Tool(name: "desktop_destroy", description: "Destroy a Desktop. Close its sessions first. Apps launched there are asked to quit.",
             schema: object([("desktopId", str("Desktop id.")), requestId], required: ["desktopId"]), method: .desktopDestroy, mutation: true),
        Tool(name: "app_list", description: "Running apps with their process identity.",
             schema: object([("includeBackground", bool("Also background-only apps."))]), method: .appList, mutation: false),
        Tool(name: "app_launch", description: "Launch an app onto a Desktop (without stealing the user's focus). Then bind its window with window_bind.",
             schema: object([("desktopId", str("Desktop id.")), ("bundleId", str("e.g. com.apple.calculator")),
                             ("path", str("Path to an .app, instead of bundleId.")), ("newInstance", bool("Start another instance if it already runs.")), requestId],
                            required: ["desktopId"]), method: .appLaunch, mutation: true),
        Tool(name: "window_list", description: "Normal windows, front to back.",
             schema: object([("pid", int("Only this process.")), ("bundleId", str("Only this app.")),
                             ("includeOffscreen", bool("Also minimized and hidden windows."))]), method: .windowList, mutation: false),
        Tool(name: "window_bind", description: "Make a window of an app launched on this Desktop with app_launch the target that observe reads and act sends input to. Windows of apps the user opened are refused (permission_denied, bind_requires_grant) until per-window grants exist.",
             schema: object([("desktopId", str("Desktop id.")), ("pid", int("Process of the window.")),
                             ("windowId", int("Optional window id; default its frontmost window.")), requestId], required: ["desktopId", "pid"]),
             method: .windowBind, mutation: true),
        Tool(name: "window_unbind", description: "Clear the Desktop's target window.",
             schema: object([("desktopId", str("Desktop id.")), requestId], required: ["desktopId"]), method: .windowUnbind, mutation: true),
        Tool(name: "session_open", description: "Open a session on a Desktop; observe, act and wait need one.",
             schema: object([("desktopId", str("Desktop id.")), requestId], required: ["desktopId"]), method: .sessionOpen, mutation: true),
        Tool(name: "session_close", description: "Close a session.",
             schema: object([session, requestId], required: ["sessionId"]), method: .sessionClose, mutation: true),
        Tool(name: "observe", description: "Screenshot and accessibility elements of the session's target window, as a new snapshot. Returns the image (possibly scaled down) and the elements with ids for act tools.",
             schema: object([session, ("query", str("Only elements whose text contains this.")),
                             ("includeImage", bool("Return the screenshot image (default true).")),
                             ("elements", bool("Read accessibility elements (default true)."))], required: ["sessionId"]),
             method: .observe, mutation: false),
        Tool(name: "act_click", description: "Click an element (elementRef) or a point of the observe image (x,y). Refused, without input, if the target changed since the snapshot.",
             schema: object([session, snapshot, element, x, y, ("button", .obj([("type", .string("string")), ("enum", .array([.string("left"), .string("right")]))])),
                             ("double", bool("Double click.")), requestId], required: ["sessionId", "snapshotId"]),
             method: .act, mutation: true),
        Tool(name: "act_type", description: "Type text into an element, or into the focused field when elementRef is omitted.",
             schema: object([session, snapshot, element, ("text", str("Text to type.")), requestId], required: ["sessionId", "snapshotId", "text"]),
             method: .act, mutation: true),
        Tool(name: "act_key", description: "Press a key (return, escape, tab, delete, up, down, left, right, a letter…) with optional modifiers.",
             schema: object([session, snapshot, ("key", str("Key name.")),
                             ("modifiers", .obj([("type", .string("array")), ("items", .obj([("enum", .array(["cmd", "shift", "option", "ctrl"].map(JSONValue.string)))]))])),
                             requestId], required: ["sessionId", "snapshotId", "key"]),
             method: .act, mutation: true),
        Tool(name: "act_scroll", description: "Scroll at an element or image point.",
             schema: object([session, snapshot, element, x, y,
                             ("direction", .obj([("type", .string("string")), ("enum", .array(["up", "down", "left", "right"].map(JSONValue.string)))])),
                             ("amount", int("Notches, 1-50 (default 3).")), requestId], required: ["sessionId", "snapshotId", "direction"]),
             method: .act, mutation: true),
        Tool(name: "wait_for_element", description: "Wait on the Runtime until an element is present (or absent) in the target window. Returns a new snapshotId to act on.",
             schema: object([session, ("present", bool("true: wait until present; false: until absent.")),
                             ("role", str("e.g. AXButton")), ("label", str("Exact label.")), ("labelContains", str("Text the label or value contains.")),
                             ("timeoutMs", int("100-60000."))], required: ["sessionId", "present", "timeoutMs"]),
             method: .wait, mutation: false),
        Tool(name: "run_show", description: "A Run: state, whether input has stopped (quiescent), receipts.",
             schema: object([("runId", str("Run id."))], required: ["runId"]), method: .runShow, mutation: false),
        Tool(name: "run_cancel", description: "Cancel a Run: accepted at once, no new input; quiescent once nothing is in flight.",
             schema: object([("runId", str("Run id.")), requestId], required: ["runId"]), method: .runCancel, mutation: true),
        Tool(name: "request_show", description: "The recorded outcome of an earlier write, by requestId — use it after an unclear failure instead of acting again.",
             schema: object([("requestId", str("Request id."))], required: ["requestId"]), method: .requestShow, mutation: false),
    ]

    static let byName: [String: Tool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
}

import AgentDesktopProtocol
import AppKit
import Foundation

/// How a picture is shown. Changing it only changes the display: it never
/// restarts the capture and never calls the Runtime (UC49).
public enum PreviewZoom: String, CaseIterable, Identifiable, Sendable {
    case fit = "适应窗口", half = "50%", actual = "100%", double = "200%"
    public var id: String { rawValue }

    /// Points per image pixel; nil fits the available space.
    public func factor(imageScale: Double?) -> CGFloat? {
        let s = CGFloat(imageScale ?? 1)
        switch self {
        case .fit: return nil
        case .half: return 0.5 / s
        case .actual: return 1 / s
        case .double: return 2 / s
        }
    }
}

/// Which Desktops have their own preview window (P08). Closing a preview
/// only removes it here and lets go of its live picture; it never touches
/// the Desktop (UC14).
@MainActor
public final class PreviewWindowRegistry: ObservableObject {
    @Published public private(set) var open: [String] = []
    /// The host shows the window for a desktopId (set by the host).
    public var present: ((String) -> Void)?
    /// The host closes the window for a desktopId.
    public var dismiss: ((String) -> Void)?
    /// The live-picture hub the preview windows use.
    public var frames: DesktopFrameHub?

    public init(frames: DesktopFrameHub? = nil) { self.frames = frames }

    /// The hub scope of a Desktop's preview window.
    public static func scope(_ desktopId: String) -> String { "preview:\(desktopId)" }

    public func show(_ desktopId: String) {
        if !open.contains(desktopId) { open.append(desktopId) }
        present?(desktopId)
    }

    /// Called when the window goes away (closed by the user or hidden):
    /// its live picture stops unless another view still shows it.
    public func closed(_ desktopId: String) {
        open.removeAll { $0 == desktopId }
        frames?.closeScope(Self.scope(desktopId))
    }

    /// The window was hidden, minimised, occluded or uncovered.
    public func setVisible(_ desktopId: String, _ visible: Bool) {
        frames?.setScopeVisible(Self.scope(desktopId), visible)
    }

    public func hide(_ desktopId: String) {
        dismiss?(desktopId)
        closed(desktopId)
    }

    /// Previews of Desktops that no longer exist close by themselves.
    public func prune(existing ids: Set<String>) {
        for id in open where !ids.contains(id) { hide(id) }
    }

    /// A good desktop list: previews of gone Desktops close and no view
    /// keeps capturing a gone Desktop's display.
    public func sync(desktops: [JSONValue]) {
        prune(existing: Set(desktops.compactMap { $0["desktopId"]?.stringValue }))
        frames?.prune(desktops: desktops)
    }
}

/// Creating a Desktop (P04 → P05): name it, then start an app on it, bind a
/// window that already exists, or leave it empty. Each step is one
/// implemented runtime/1 call (desktop.create, then app.launch or
/// window.bind), shown with the state the Runtime gave it; there is no
/// invented progress. A failed step keeps its error and can be retried on
/// its own: a Desktop already created is not created twice.
@MainActor
public final class CreateDesktopFlow: ObservableObject {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case empty = "空 Desktop", launch = "启动应用", bind = "绑定已有窗口"
        public var id: String { rawValue }
    }

    public enum StepState: Equatable, Sendable {
        case pending, running, done, failed(RuntimeProblem), skipped
    }

    public static let sizes: [(String, Int, Int)] = [("1280 × 800", 1280, 800), ("1440 × 900", 1440, 900),
                                                      ("1920 × 1080", 1920, 1080)]

    @Published public var name = ""
    @Published public var mode: Mode = .empty
    @Published public var showSize = false
    @Published public var width = 1280
    @Published public var height = 800
    @Published public var bundleId = ""
    /// For `bind`: the chosen window (window.list entry).
    @Published public var window: JSONValue?
    @Published public private(set) var nameError: String?
    @Published public private(set) var choiceError: String?
    @Published public private(set) var apps: [JSONValue] = []
    @Published public private(set) var windows: [JSONValue] = []
    @Published public private(set) var choicesProblem: RuntimeProblem?
    @Published public private(set) var createStep: StepState = .pending
    @Published public private(set) var attachStep: StepState = .pending
    @Published public private(set) var desktop: JSONValue?
    /// The app.launch answer, once the app runs: a retry binds its window
    /// and never launches a second copy.
    @Published public private(set) var launched: JSONValue?

    private let runtime: RuntimePort

    /// Whether the size came from the saved preference (P21): then it is
    /// sent even when the size field is folded away.
    public private(set) var sizeFromPreference = false

    public init(runtime: RuntimePort, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        let size = SettingsPreferences(defaults: defaults).saved.defaultDesktopSize
        if size != SettingsDesktopSize.standard {
            width = size.width
            height = size.height
            sizeFromPreference = true
        }
    }

    public var desktopId: String? { desktop?["desktopId"]?.stringValue }
    public var isWorking: Bool { createStep == .running || attachStep == .running }
    public var isDone: Bool { createStep == .done && (attachStep == .done || attachStep == .skipped) }
    public var hasFailed: Bool {
        if case .failed = createStep { return true }
        if case .failed = attachStep { return true }
        return false
    }
    /// The form is shown until the first submission is under way.
    public var started: Bool { createStep != .pending }

    /// Apps (for a bundle ID to launch) and windows (to bind).
    public func loadChoices() async {
        do {
            let a = try await runtime.call("app.list")
            let w = try await runtime.call("window.list")
            apps = (a["apps"]?.arrayValue ?? []).filter { $0["bundleId"]?.stringValue != nil }
            windows = w["windows"]?.arrayValue ?? []
            choicesProblem = nil
        } catch {
            choicesProblem = RuntimeProblem(error)
        }
    }

    /// In-place checks before anything is sent (UC03).
    @discardableResult
    public func validate() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nameError = "请填写名称"
        } else if trimmed.count > 64 {
            nameError = "名称最多 64 个字符"
        } else {
            nameError = nil
        }
        switch mode {
        case .empty: choiceError = nil
        case .launch: choiceError = bundleId.trimmingCharacters(in: .whitespaces).isEmpty ? "请选择或填写要启动的应用" : nil
        case .bind: choiceError = window == nil ? "请选择一个窗口" : nil
        }
        if showSize, !(320...6016).contains(width) || !(240...3384).contains(height) {
            choiceError = "尺寸需在 320×240 到 6016×3384 之间"
        }
        return nameError == nil && choiceError == nil
    }

    public func submit() async {
        guard !isWorking, validate() else { return }
        if desktop == nil { await runCreate() }
        guard desktop != nil else { return }
        await runAttach()
    }

    /// Retry only the step that failed.
    public func retry() async {
        guard !isWorking else { return }
        if desktop == nil { await runCreate() }
        guard desktop != nil else { return }
        if case .failed = attachStep { attachStep = .pending }
        if attachStep == .pending { await runAttach() }
    }

    private func runCreate() async {
        createStep = .running
        var p: [(String, JSONValue)] = [("name", .string(name.trimmingCharacters(in: .whitespacesAndNewlines)))]
        if showSize || sizeFromPreference { p += [("width", .int(width)), ("height", .int(height))] }
        do {
            desktop = try await runtime.call("desktop.create", .obj(p))
            createStep = .done
        } catch {
            createStep = .failed(RuntimeProblem(error))
        }
    }

    /// What app.launch gets: a path for an `.app` given by path, else the
    /// bundle ID.
    var launchTarget: (String, JSONValue) {
        let v = bundleId.trimmingCharacters(in: .whitespaces)
        return v.hasPrefix("/") || v.hasPrefix("~") || v.hasSuffix(".app") ? ("path", .string(v)) : ("bundleId", .string(v))
    }

    private func runAttach() async {
        guard let id = desktopId else { return }
        switch mode {
        case .empty:
            attachStep = .skipped
            return
        case .launch:
            attachStep = .running
            do {
                // Launch places the app's window on the Desktop; binding
                // makes that window the Desktop's input target.
                if launched == nil {
                    launched = try await runtime.call("app.launch", .obj([("desktopId", .string(id)), launchTarget,
                                                                          ("newInstance", .bool(true))]))
                }
                guard let l = launched, let pid = l["process"]?["pid"]?.intValue else {
                    throw RuntimeError("internal_error", "app.launch answered without a process", phase: .handler)
                }
                var p: [(String, JSONValue)] = [("desktopId", .string(id)), ("pid", .int(pid))]
                if let wid = l["windows"]?.arrayValue?.first?["windowId"]?.intValue { p.append(("windowId", .int(wid))) }
                _ = try await runtime.call("window.bind", .obj(p))
                attachStep = .done
            } catch {
                attachStep = .failed(RuntimeProblem(error))
            }
        case .bind:
            guard let w = window, let pid = w["process"]?["pid"]?.intValue else { return }
            attachStep = .running
            var p: [(String, JSONValue)] = [("desktopId", .string(id)), ("pid", .int(pid))]
            if let wid = w["windowId"]?.intValue { p.append(("windowId", .int(wid))) }
            do {
                _ = try await runtime.call("window.bind", .obj(p))
                attachStep = .done
            } catch {
                attachStep = .failed(RuntimeProblem(error))
            }
        }
        if attachStep == .done, let d = try? await runtime.call("desktop.show", .obj([("desktopId", .string(id))])) {
            desktop = d
        }
    }
}

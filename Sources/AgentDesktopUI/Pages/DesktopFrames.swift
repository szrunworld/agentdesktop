import AgentDesktopProtocol
import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

// The live picture of a Desktop (P06, P07, P08) comes from a capture of the
// Desktop's own display (ScreenCaptureKit in the app), not from the
// Runtime's `observe`: observe writes an artifact and its sidecar for every
// call and is meant for agent observations and evidence. Live frames live
// only in memory, one per display, and are never written anywhere. They
// have no snapshotId.

/// One frame of a Desktop's live picture, held in memory only.
public final class DesktopFrame: @unchecked Sendable {
    public let image: CGImage
    /// Image pixels per Desktop point; below 1 when the capture was scaled
    /// down to fit the preview's width cap.
    public let scale: Double
    public let capturedAt: Date

    public init(image: CGImage, scale: Double, capturedAt: Date = Date()) {
        self.image = image
        self.scale = scale
        self.capturedAt = capturedAt
    }

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
}

/// Why a source cannot deliver frames.
public enum DesktopFrameProblem: Equatable, Sendable {
    /// The process lacks the Screen Recording permission.
    case permissionDenied
    /// Capture failed or the display is not capturable; the reason is shown.
    case unavailable(String)
}

/// What a live picture is doing, as the views show it.
public enum DesktopFrameStatus: Equatable, Sendable {
    case starting
    case live
    /// No visible consumer (window closed, hidden or occluded); the last
    /// frame stays on screen.
    case paused
    case permissionDenied
    case unavailable(String)
}

/// What a source is asked to capture.
public struct DesktopFrameRequest: Equatable, Sendable {
    public let displayId: UInt32
    /// Frames wider than this are scaled down by the capture itself.
    public let maxPixelWidth: Int
    public let framesPerSecond: Int

    public init(displayId: UInt32, maxPixelWidth: Int, framesPerSecond: Int) {
        self.displayId = displayId
        self.maxPixelWidth = maxPixelWidth
        self.framesPerSecond = framesPerSecond
    }
}

/// A stream of frames for one display. `start` delivers on the main actor
/// until `stop`; a source never writes a frame to disk.
@MainActor
public protocol DesktopFrameSource: AnyObject {
    func start(frame: @escaping @MainActor (DesktopFrame) -> Void,
               failure: @escaping @MainActor (DesktopFrameProblem) -> Void)
    func stop()
}

public typealias DesktopFrameSourceFactory = @MainActor (DesktopFrameRequest) -> DesktopFrameSource

/// The latest frame and status of one display, shared by every view that
/// shows it. Only the latest frame is kept.
@MainActor
public final class DesktopFrameFeed: ObservableObject {
    public let displayId: UInt32
    @Published public private(set) var frame: DesktopFrame?
    @Published public private(set) var status: DesktopFrameStatus = .starting
    /// Frames received since the feed was made (tests, diagnostics).
    public private(set) var framesReceived = 0

    init(displayId: UInt32) { self.displayId = displayId }

    func receive(_ f: DesktopFrame) {
        framesReceived += 1
        frame = f
        if status != .live { status = .live }
    }

    func set(_ s: DesktopFrameStatus) {
        if status != s { status = s }
    }
}

/// One capture stream per display, shared by all consumers (the detail
/// page, the side-by-side panel, the overview card, the preview window).
/// A display streams while at least one consumer in a visible scope holds
/// it; its feed, with the last frame, lives while any consumer holds it.
/// Scopes are windows: `main` for the main window, one per preview window.
@MainActor
public final class DesktopFrameHub {
    public struct Token: Hashable, Sendable {
        let id: Int
        public let displayId: UInt32
        public let scope: String
    }

    public nonisolated static let mainScope = "main"
    /// Live preview limits: at most this many frames a second, at most this
    /// wide in pixels (the preview never needs more).
    public nonisolated static let defaultFramesPerSecond = 4
    public nonisolated static let defaultMaxPixelWidth = 1600

    public let framesPerSecond: Int
    public let maxPixelWidth: Int
    private let makeSource: DesktopFrameSourceFactory
    private var consumers: [Int: Token] = [:]
    private var feeds: [UInt32: DesktopFrameFeed] = [:]
    private var sources: [UInt32: DesktopFrameSource] = [:]
    /// Displays whose source failed; not restarted until a retry or until
    /// every consumer has let go.
    private var failed: Set<UInt32> = []
    private var hiddenScopes: Set<String> = []
    private var nextId = 0
    /// Sources started over the hub's life (tests, diagnostics).
    public private(set) var startedCount = 0
    /// How long a released display keeps its stream before it stops.
    /// SwiftUI may run the old view's onDisappear before the new view's
    /// onAppear when moving between pages of the same Desktop; without a
    /// grace the stream would stop and start again in between.
    public let releaseGraceMs: Int
    private var graceTask: Task<Void, Never>?

    public init(framesPerSecond: Int = DesktopFrameHub.defaultFramesPerSecond,
                maxPixelWidth: Int = DesktopFrameHub.defaultMaxPixelWidth,
                releaseGraceMs: Int = 0,
                makeSource: @escaping DesktopFrameSourceFactory) {
        self.framesPerSecond = max(1, min(5, framesPerSecond))
        self.maxPixelWidth = max(1, maxPixelWidth)
        self.releaseGraceMs = max(0, releaseGraceMs)
        self.makeSource = makeSource
    }

    /// Displays with a running capture stream.
    public var streamingDisplays: Set<UInt32> { Set(sources.keys) }
    public var streamCount: Int { sources.count }
    public var consumerCount: Int { consumers.count }
    /// Frames held in memory: at most one per display with a consumer.
    public var retainedFrameCount: Int { feeds.values.filter { $0.frame != nil }.count }

    public func feed(_ displayId: UInt32) -> DesktopFrameFeed? { feeds[displayId] }

    public func isScopeVisible(_ scope: String) -> Bool { !hiddenScopes.contains(scope) }

    /// The display a Desktop lives on (`screen.displayId`), if valid.
    public static func displayId(of desktop: JSONValue?) -> UInt32? {
        guard let v = desktop?["screen"]?["displayId"]?.intValue, v > 0, v <= Int(UInt32.max) else { return nil }
        return UInt32(v)
    }

    public func acquire(displayId: UInt32, scope: String) -> (Token, DesktopFrameFeed) {
        nextId += 1
        let token = Token(id: nextId, displayId: displayId, scope: scope)
        consumers[token.id] = token
        let feed = feeds[displayId] ?? DesktopFrameFeed(displayId: displayId)
        feeds[displayId] = feed
        reconcile()
        return (token, feed)
    }

    /// Idempotent: releasing a token twice, or one whose scope was closed,
    /// does nothing.
    public func release(_ token: Token) {
        guard consumers.removeValue(forKey: token.id) != nil else { return }
        guard releaseGraceMs > 0 else { reconcile(); return }
        // A consumer that comes back within the grace keeps the stream;
        // acquiring reconciles at once, so only stopping waits.
        graceTask?.cancel()
        let ms = releaseGraceMs
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            self.graceTask = nil
            self.reconcile()
        }
    }

    /// A window was shown, hidden, occluded or uncovered.
    public func setScopeVisible(_ scope: String, _ visible: Bool) {
        let changed = visible ? hiddenScopes.remove(scope) != nil : hiddenScopes.insert(scope).inserted
        if changed { reconcile() }
    }

    /// A window went away: every consumer in it lets go.
    public func closeScope(_ scope: String) {
        let before = consumers.count
        consumers = consumers.filter { $0.value.scope != scope }
        hiddenScopes.remove(scope)
        if consumers.count != before { reconcile() }
    }

    /// Desktops that no longer exist: consumers of their displays let go.
    public func prune(keeping displays: Set<UInt32>) {
        let before = consumers.count
        consumers = consumers.filter { displays.contains($0.value.displayId) }
        if consumers.count != before { reconcile() }
    }

    public func prune(desktops: [JSONValue]) {
        prune(keeping: Set(desktops.compactMap { Self.displayId(of: $0) }))
    }

    /// The user asked to try again after a failure.
    public func retry(_ displayId: UInt32) {
        failed.remove(displayId)
        sources.removeValue(forKey: displayId)?.stop()
        reconcile()
    }

    /// App quit: stop every stream and drop every frame.
    public func stopAll() {
        graceTask?.cancel()
        graceTask = nil
        consumers.removeAll()
        reconcile()
    }

    private func reconcile() {
        let held = Set(consumers.values.map(\.displayId))
        let wanted = Set(consumers.values.filter { !hiddenScopes.contains($0.scope) }.map(\.displayId))
        for d in Array(sources.keys) where !wanted.contains(d) {
            sources.removeValue(forKey: d)?.stop()
        }
        // Held only by hidden windows: paused, whether it ran or not yet.
        for d in held.subtracting(wanted) where feeds[d]?.status == .live || feeds[d]?.status == .starting {
            feeds[d]?.set(.paused)
        }
        for d in Array(feeds.keys) where !held.contains(d) { feeds[d] = nil }
        failed.formIntersection(held)
        for d in wanted.sorted() where sources[d] == nil && !failed.contains(d) { start(d) }
    }

    private func start(_ d: UInt32) {
        guard let feed = feeds[d] else { return }
        feed.set(.starting)
        let source = makeSource(DesktopFrameRequest(displayId: d, maxPixelWidth: maxPixelWidth, framesPerSecond: framesPerSecond))
        sources[d] = source
        startedCount += 1
        source.start(frame: { [weak self, weak source] f in
            guard let self, let source, self.sources[d] === source else { return }
            self.feeds[d]?.receive(f)
        }, failure: { [weak self, weak source] p in
            guard let self, let source, self.sources[d] === source else { return }
            self.sources[d] = nil
            source.stop()
            self.failed.insert(d)
            switch p {
            case .permissionDenied: self.feeds[d]?.set(.permissionDenied)
            case .unavailable(let why): self.feeds[d]?.set(.unavailable(why))
            }
        })
    }
}

/// One view's hold on a display's feed. Attach when the view appears,
/// detach when it disappears; a lease dropped without detaching lets go on
/// its own.
@MainActor
public final class DesktopFrameLease: ObservableObject {
    @Published public private(set) var feed: DesktopFrameFeed?
    /// Why there is no feed (no hub in this window, no display).
    @Published public private(set) var unattached: DesktopFrameStatus?
    private let box = ReleaseBox()
    private var forward: AnyCancellable?
    private var scope = DesktopFrameHub.mainScope

    public init() {}

    deinit {
        let box = self.box
        Task { @MainActor in box.release() }
    }

    public var frame: DesktopFrame? { feed?.frame }
    public var status: DesktopFrameStatus { feed?.status ?? unattached ?? .starting }
    public var isAttached: Bool { box.token != nil }

    public func attach(_ hub: DesktopFrameHub?, displayId: UInt32?, scope: String = DesktopFrameHub.mainScope) {
        if let t = box.token, box.hub === hub, t.displayId == displayId, t.scope == scope { return }
        detach()
        guard let hub else {
            unattached = .unavailable("这个窗口没有接入实时画面。")
            return
        }
        guard let displayId else {
            unattached = .unavailable("Runtime 没有给出这个 Desktop 的显示器。")
            return
        }
        let (token, feed) = hub.acquire(displayId: displayId, scope: scope)
        box.hub = hub
        box.token = token
        self.scope = scope
        unattached = nil
        self.feed = feed
        forward = feed.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public func detach() {
        box.release()
        forward = nil
        feed = nil
    }

    public func retry() {
        guard let t = box.token else { return }
        box.hub?.retry(t.displayId)
    }

    /// Holds what deinit needs without touching main-actor state.
    private final class ReleaseBox: @unchecked Sendable {
        weak var hub: DesktopFrameHub?
        var token: DesktopFrameHub.Token?

        @MainActor func release() {
            if let token { hub?.release(token) }
            token = nil
            hub = nil
        }
    }
}

private struct DesktopFramesKey: EnvironmentKey {
    static var defaultValue: DesktopFrameHub? { nil }
}

public extension EnvironmentValues {
    /// The live-picture hub of this window; none means no live picture
    /// (renders, tests), shown as such.
    var desktopFrames: DesktopFrameHub? {
        get { self[DesktopFramesKey.self] }
        set { self[DesktopFramesKey.self] = newValue }
    }
}

/// Holds a display's feed while the view is on screen.
struct LiveFrameAttachment: ViewModifier {
    @Environment(\.desktopFrames) private var hub
    @ObservedObject var lease: DesktopFrameLease
    let displayId: UInt32?
    let scope: String

    func body(content: Content) -> some View {
        content
            .onAppear { lease.attach(hub, displayId: displayId, scope: scope) }
            .onDisappear { lease.detach() }
            .onChange(of: displayId) { _, new in lease.attach(hub, displayId: new, scope: scope) }
    }
}

public extension View {
    func liveFrame(_ lease: DesktopFrameLease, displayId: UInt32?, scope: String = DesktopFrameHub.mainScope) -> some View {
        modifier(LiveFrameAttachment(lease: lease, displayId: displayId, scope: scope))
    }
}

/// A scripted source for tests and renders: frames are pushed by hand.
@MainActor
public final class FakeDesktopFrameSource: DesktopFrameSource {
    public let request: DesktopFrameRequest
    public private(set) var isRunning = false
    public private(set) var stopCount = 0
    /// A failure reported as soon as the source starts.
    public var failOnStart: DesktopFrameProblem?
    private var deliver: (@MainActor (DesktopFrame) -> Void)?
    private var fail: (@MainActor (DesktopFrameProblem) -> Void)?

    public init(request: DesktopFrameRequest) { self.request = request }

    public func start(frame: @escaping @MainActor (DesktopFrame) -> Void,
                      failure: @escaping @MainActor (DesktopFrameProblem) -> Void) {
        isRunning = true
        deliver = frame
        fail = failure
        if let p = failOnStart { failure(p) }
    }

    public func stop() {
        stopCount += 1
        isRunning = false
        deliver = nil
        fail = nil
    }

    public func push(_ frame: DesktopFrame) { if isRunning { deliver?(frame) } }

    public func push(width: Int, height: Int, scale: Double = 1) {
        push(DesktopFrame(image: Self.image(width: width, height: height), scale: scale))
    }

    public func failNow(_ p: DesktopFrameProblem) { if isRunning { fail?(p) } }

    public static func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

/// Makes fake sources and remembers them (tests).
@MainActor
public final class FakeDesktopFrames {
    public private(set) var made: [FakeDesktopFrameSource] = []
    public var failOnStart: [UInt32: DesktopFrameProblem] = [:]
    public lazy var hub = DesktopFrameHub { [unowned self] request in
        let s = FakeDesktopFrameSource(request: request)
        s.failOnStart = self.failOnStart[request.displayId]
        self.made.append(s)
        return s
    }

    public init() {}

    public var running: [FakeDesktopFrameSource] { made.filter(\.isRunning) }
    public func running(_ displayId: UInt32) -> FakeDesktopFrameSource? { running.first { $0.request.displayId == displayId } }
}

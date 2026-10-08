import AgentDesktopProtocol
import Foundation

// Results of the PR1 methods (runtime.schema.json). Each type writes the
// exact JSON shape and reads it back; the schema tests check both ways.

public enum Timestamp {
    public static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public struct Platform: Equatable, Sendable {
    public var os: String
    public var osVersion: String
    public var arch: String

    public init(os: String, osVersion: String, arch: String) {
        self.os = os
        self.osVersion = osVersion
        self.arch = arch
    }

    public static var current: Platform {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return Platform(os: "macos", osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", arch: arch)
    }

    public var json: JSONValue {
        .obj([("os", .string(os)), ("osVersion", .string(osVersion)), ("arch", .string(arch))])
    }

    public init?(json: JSONValue?) {
        guard let os = json?["os"]?.stringValue, let v = json?["osVersion"]?.stringValue,
              let a = json?["arch"]?.stringValue else { return nil }
        self.init(os: os, osVersion: v, arch: a)
    }
}

/// Who answered: product, API version and this launch of the Runtime.
public struct RuntimeIdentity: Equatable, Sendable {
    public var product: String
    public var productVersion: String
    public var apiVersion: String
    public var apiVersions: [String]
    public var instanceId: String
    public var pid: Int32
    public var startedAt: String
    public var endpoint: String
    public var platform: Platform
    public var buildSource: String
    public var builtAt: String?

    public init(product: String = RuntimeAPI.product, productVersion: String = RuntimeAPI.productVersion,
                apiVersion: String = RuntimeAPI.version, apiVersions: [String] = RuntimeAPI.supportedVersions,
                instanceId: String, pid: Int32, startedAt: String, endpoint: String,
                platform: Platform = .current, buildSource: String, builtAt: String? = nil) {
        self.product = product
        self.productVersion = productVersion
        self.apiVersion = apiVersion
        self.apiVersions = apiVersions
        self.instanceId = instanceId
        self.pid = pid
        self.startedAt = startedAt
        self.endpoint = endpoint
        self.platform = platform
        self.buildSource = buildSource
        self.builtAt = builtAt
    }

    public var json: JSONValue {
        var build: [(String, JSONValue)] = [("source", .string(buildSource))]
        if let builtAt { build.append(("builtAt", .string(builtAt))) }
        return .obj([
            ("product", .string(product)),
            ("productVersion", .string(productVersion)),
            ("apiVersion", .string(apiVersion)),
            ("apiVersions", .array(apiVersions.map(JSONValue.string))),
            ("instanceId", .string(instanceId)),
            ("pid", .int(Int(pid))),
            ("startedAt", .string(startedAt)),
            ("endpoint", .string(endpoint)),
            ("platform", platform.json),
            ("build", .obj(build)),
        ])
    }

    public init?(json v: JSONValue) {
        guard let product = v["product"]?.stringValue, let pv = v["productVersion"]?.stringValue,
              let api = v["apiVersion"]?.stringValue, let apis = v["apiVersions"]?.arrayValue,
              let instance = v["instanceId"]?.stringValue, let pid = v["pid"]?.intValue,
              let started = v["startedAt"]?.stringValue, let endpoint = v["endpoint"]?.stringValue,
              let platform = Platform(json: v["platform"]), let source = v["build"]?["source"]?.stringValue
        else { return nil }
        self.init(product: product, productVersion: pv, apiVersion: api,
                  apiVersions: apis.compactMap(\.stringValue), instanceId: instance, pid: Int32(pid),
                  startedAt: started, endpoint: endpoint, platform: platform, buildSource: source,
                  builtAt: v["build"]?["builtAt"]?.stringValue)
    }
}

/// Provenance of an installed build: Contents/Resources/build.json written
/// by scripts/bundle-app.sh, or "unknown" when run from a source build.
public struct BuildInfo: Equatable, Sendable {
    public var source: String
    public var builtAt: String?

    public static let unknown = BuildInfo(source: "unknown", builtAt: nil)

    public init(source: String, builtAt: String?) {
        self.source = source
        self.builtAt = builtAt
    }

    /// Read build.json from a bundle's Resources directory.
    public static func load(resourcesDirectory: URL) -> BuildInfo {
        guard let data = try? Data(contentsOf: resourcesDirectory.appendingPathComponent("build.json")),
              let v = try? StrictJSON.parse(data), let source = v["source"]?.stringValue
        else { return .unknown }
        return BuildInfo(source: source, builtAt: v["builtAt"]?.stringValue)
    }
}

public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public var pid: Int32
    /// Start time of the process; with the pid it names one launch.
    public var startedAt: String?

    public init(pid: Int32, startedAt: String?) {
        self.pid = pid
        self.startedAt = startedAt
    }

    public var json: JSONValue {
        .obj([("pid", .int(Int(pid))), ("startedAt", startedAt.map(JSONValue.string) ?? .null)])
    }

    public init?(json: JSONValue?) {
        guard let pid = json?["pid"]?.intValue else { return nil }
        self.init(pid: Int32(pid), startedAt: json?["startedAt"]?.stringValue)
    }
}

public enum PermissionState: String, Sendable {
    case granted, denied, unknown
}

public struct BackendPermissions: Equatable, Sendable {
    public var screenRecording: PermissionState
    public var accessibility: PermissionState

    public init(screenRecording: PermissionState, accessibility: PermissionState) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

public struct RuntimeStatus: Equatable, Sendable {
    public var instanceId: String
    public var state: String
    public var startedAt: String
    public var uptimeSeconds: Double
    public var connections: Int
    public var desktops: Int
    public var sessions: Int
    public var runs: Int

    public init(instanceId: String, state: String, startedAt: String, uptimeSeconds: Double,
                connections: Int, desktops: Int, sessions: Int, runs: Int) {
        self.instanceId = instanceId
        self.state = state
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.connections = connections
        self.desktops = desktops
        self.sessions = sessions
        self.runs = runs
    }

    public var json: JSONValue {
        .obj([
            ("instanceId", .string(instanceId)),
            ("state", .string(state)),
            ("startedAt", .string(startedAt)),
            ("uptimeSeconds", .double((uptimeSeconds * 1000).rounded() / 1000)),
            ("connections", .int(connections)),
            ("desktops", .int(desktops)),
            ("sessions", .int(sessions)),
            ("runs", .int(runs)),
        ])
    }
}

public struct Desktop: Equatable, Sendable {
    public var desktopId: String
    public var name: String
    public var state: String
    public var createdAt: String

    public init(desktopId: String, name: String, state: String, createdAt: String) {
        self.desktopId = desktopId
        self.name = name
        self.state = state
        self.createdAt = createdAt
    }

    public var json: JSONValue {
        .obj([("desktopId", .string(desktopId)), ("name", .string(name)),
              ("state", .string(state)), ("createdAt", .string(createdAt))])
    }
}

public struct AppSummary: Equatable, Sendable {
    public var process: ProcessIdentity
    public var bundleId: String?
    public var name: String
    public var active: Bool
    public var hidden: Bool

    public init(process: ProcessIdentity, bundleId: String?, name: String, active: Bool, hidden: Bool) {
        self.process = process
        self.bundleId = bundleId
        self.name = name
        self.active = active
        self.hidden = hidden
    }

    public var json: JSONValue {
        .obj([("process", process.json), ("bundleId", bundleId.map(JSONValue.string) ?? .null),
              ("name", .string(name)), ("active", .bool(active)), ("hidden", .bool(hidden))])
    }
}

public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var json: JSONValue {
        .obj([("x", .double(x)), ("y", .double(y)), ("width", .double(width)), ("height", .double(height))])
    }
}

public struct WindowSummary: Equatable, Sendable {
    public var windowId: UInt32
    public var process: ProcessIdentity
    public var appName: String
    public var bundleId: String?
    /// nil when the OS withholds the title.
    public var title: String?
    /// Global points, top-left origin.
    public var frame: Rect
    public var onScreen: Bool

    public init(windowId: UInt32, process: ProcessIdentity, appName: String, bundleId: String?,
                title: String?, frame: Rect, onScreen: Bool) {
        self.windowId = windowId
        self.process = process
        self.appName = appName
        self.bundleId = bundleId
        self.title = title
        self.frame = frame
        self.onScreen = onScreen
    }

    public var json: JSONValue {
        .obj([
            ("windowId", .int(Int(windowId))),
            ("process", process.json),
            ("appName", .string(appName)),
            ("bundleId", bundleId.map(JSONValue.string) ?? .null),
            ("title", title.map(JSONValue.string) ?? .null),
            ("frame", frame.json),
            ("onScreen", .bool(onScreen)),
        ])
    }
}

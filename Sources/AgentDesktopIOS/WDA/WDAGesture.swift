import Foundation

/// A point in WDA's coordinate space: logical points of the device screen
/// in the current orientation (screenshot pixels divided by the screen
/// scale, see `WDAObservation.screenScale`).
public struct WDAPoint: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Touch gestures, all sent as one W3C Actions request
/// (`POST /session/:id/actions`). The JSONWP TouchActions routes removed
/// from current WDA are never used.
public enum WDAGesture: Sendable, Equatable {
    case tap(WDAPoint)
    /// Finger down, move to `to` over `duration`, finger up. Scrolls lists.
    case swipe(from: WDAPoint, to: WDAPoint, duration: Duration)
    /// Finger down, hold `hold` so iOS starts a drag, move over `duration`,
    /// settle, finger up.
    case drag(from: WDAPoint, to: WDAPoint, hold: Duration, duration: Duration)
    case longPress(WDAPoint, duration: Duration)

    public var operation: String {
        switch self {
        case .tap: return "tap"
        case .swipe: return "swipe"
        case .drag: return "drag"
        case .longPress: return "longPress"
        }
    }

    /// Time to keep the finger still at the drop point before lifting it.
    static let dropSettle: Duration = .milliseconds(150)
    /// Finger contact time of a tap.
    static let tapContact: Duration = .milliseconds(50)

    /// The W3C pointer action items of this gesture, in order.
    public var pointerSequence: [WDAPointerStep] {
        switch self {
        case let .tap(point):
            return [.move(point, duration: .zero), .down, .pause(Self.tapContact), .up]
        case let .swipe(from, to, duration):
            return [.move(from, duration: .zero), .down, .move(to, duration: duration), .up]
        case let .drag(from, to, hold, duration):
            return [.move(from, duration: .zero), .down, .pause(hold),
                    .move(to, duration: duration), .pause(Self.dropSettle), .up]
        case let .longPress(point, duration):
            return [.move(point, duration: .zero), .down, .pause(duration), .up]
        }
    }

    func validate() -> String? {
        func bad(_ p: WDAPoint) -> Bool { !p.x.isFinite || !p.y.isFinite || p.x < 0 || p.y < 0 }
        func negative(_ d: Duration) -> Bool { d < .zero }
        switch self {
        case let .tap(p):
            return bad(p) ? "tap point must be finite and non-negative" : nil
        case let .swipe(a, b, d):
            if bad(a) || bad(b) { return "swipe points must be finite and non-negative" }
            if negative(d) { return "swipe duration must not be negative" }
            if a == b { return "swipe start and end are the same point" }
            return nil
        case let .drag(a, b, h, d):
            if bad(a) || bad(b) { return "drag points must be finite and non-negative" }
            if negative(h) || negative(d) { return "drag durations must not be negative" }
            return nil
        case let .longPress(p, d):
            if bad(p) { return "long press point must be finite and non-negative" }
            if d <= .zero { return "long press duration must be positive" }
            return nil
        }
    }

    /// The request body: one touch pointer source named `finger1`.
    public func w3cActionsBody() -> [String: Any] {
        [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": pointerSequence.map(\.json),
            ] as [String: Any]],
        ]
    }
}

public enum WDAPointerStep: Sendable, Equatable {
    case move(WDAPoint, duration: Duration)
    case down
    case pause(Duration)
    case up

    var json: [String: Any] {
        switch self {
        case let .move(point, duration):
            return ["type": "pointerMove", "duration": duration.wdaMilliseconds,
                    "x": point.x, "y": point.y, "origin": "viewport"]
        case .down:
            return ["type": "pointerDown", "button": 0]
        case let .pause(duration):
            return ["type": "pause", "duration": duration.wdaMilliseconds]
        case .up:
            return ["type": "pointerUp", "button": 0]
        }
    }
}

extension Duration {
    /// Whole milliseconds, as W3C Actions expects.
    var wdaMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

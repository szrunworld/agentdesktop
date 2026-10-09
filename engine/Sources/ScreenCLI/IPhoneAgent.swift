import AppKit
import Foundation
import SecondScreenCore
import TarsAgent

/// `agentdesktop iphone ...`: iPhone Mirroring on an agent screen, used like an
/// Android phone's mirror. Nothing here moves the user's pointer: taps and
/// keys go to the window in the background, and only pasting text brings
/// Mirroring to the front, for about a second.
enum IPhoneCommands {
    /// Screenshot pixels per window point; tap coordinates are in pixels.
    static let pixelsPerPoint: CGFloat = 2

    static let usage = """
        usage:
          agentdesktop iphone show [--screen NAME]
          agentdesktop iphone hide [--timeout SECONDS] [--no-wait]
          agentdesktop iphone status [--screen NAME]
          agentdesktop iphone reconnect [--screen NAME] [--timeout SECONDS] [--phone-locked]
          agentdesktop iphone screenshot [--screen NAME] --output FILE.png
          agentdesktop iphone tap  [--screen NAME] --x X --y Y [--geometry VERSION]
          agentdesktop iphone type [--screen NAME] --text TEXT [--geometry VERSION]
          agentdesktop iphone key  [--screen NAME] --key home|switcher|spotlight|return|delete|KEY [--geometry VERSION]

        Points are the screenshot's pixels, two to a window point. screenshot
        prints the window it showed and its geometry version; give that as
        --geometry and the input is refused (stale_observation, nothing sent)
        if the window has since moved, resized or been replaced.
        status and screenshot only read; reconnect presses Connect / Try Again
        / Resume on a disconnected window and waits for it to settle. On
        "iPhone in Use" it presses nothing: that page stays after the phone
        is locked, until Connect is pressed. Lock the phone, then give
        --phone-locked to have reconnect press it.
        """

    static func run(_ args: Arguments) -> Never {
        let name = args.value("--screen") ?? "phone"
        switch args.positional.dropFirst().first {
        case "show", "setup": show(screen: name)
        case "hide": hide(args)
        case "status": status(screen: name)
        case "reconnect": reconnect(screen: name, args)
        case "screenshot": screenshot(screen: name, args)
        case "tap", "type", "key": act(args.positional[1], screen: name, args)
        default: fail(usage)
        }
    }

    private static func seconds(_ args: Arguments, default value: TimeInterval) -> TimeInterval {
        guard let text = args.value("--timeout") else { return value }
        guard let seconds = TimeInterval(text), seconds >= 0 else { fail("--timeout needs a number of seconds") }
        return seconds
    }

    /// Make the agent screen if need be and put iPhone Mirroring on it,
    /// launching it in the background when it is not running. Running it
    /// again makes no second screen.
    private static func show(screen name: String) -> Never {
        do {
            let shown = try IPhoneLifecycle(system: LiveIPhoneMirroringSystem()).show(screen: name)
            var output: [String: Any] = ["ok": shown.ok, "screen": name, "screenCreated": shown.screenCreated,
                                         "mirroring": shown.mirroring]
            if let pid = shown.pid { output["pid"] = Int(pid) }
            if let error = shown.error { output["error"] = error }
            DriverCommands.emit(output)
            exit(shown.ok ? 0 : 1)
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    /// Quit iPhone Mirroring, which hands the phone back to its owner, and
    /// wait until it has gone: exited, timed_out, refused, not_running, or
    /// exit_requested with --no-wait.
    private static func hide(_ args: Arguments) -> Never {
        let result = IPhoneLifecycle(system: LiveIPhoneMirroringSystem())
            .hide(wait: !args.has("--no-wait"), timeout: seconds(args, default: 10))
        DriverCommands.emit(["ok": result.outcome.ok, "state": result.outcome.rawValue,
                             "pids": result.pids.map(Int.init)])
        exit(result.outcome.ok ? 0 : 1)
    }

    private static func status(screen name: String) -> Never {
        do {
            let phone = IPhoneAgentScreen(screen: name)
            let (state, label) = try phone.connectionState()
            var output: [String: Any] = ["ok": true, "state": state.rawValue, "hint": state.hint]
            if let label { output["shows"] = label }
            if let binding = phone.binding { output["windowID"] = Int(binding.windowID) }
            DriverCommands.emit(output)
            exit(0)
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    private static func reconnect(screen name: String, _ args: Arguments) -> Never {
        do {
            let phone = IPhoneAgentScreen(screen: name)
            let report = try phone.reconnect(timeout: seconds(args, default: 20), phoneLocked: args.has("--phone-locked"))
            // ok only when the phone was confirmed ready, never because the
            // last look happened to show it (F8).
            var output: [String: Any] = ["ok": report.isReady, "outcome": report.outcome.rawValue,
                                         "phase": report.phase.rawValue, "generation": report.generation,
                                         "readyReadings": report.readyReadings,
                                         "state": report.state.rawValue, "hint": report.state.hint,
                                         "timedOut": report.timedOut]
            if let label = report.label { output["shows"] = label }
            if let pressed = report.pressed { output["pressed"] = pressed }
            if let blocked = report.blockedBy { output["blockedBy"] = blocked }
            DriverCommands.emit(output)
            exit(report.isReady ? 0 : 1)
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    private static func screenshot(screen name: String, _ args: Arguments) -> Never {
        guard let output = args.value("--output") else { fail("iphone screenshot needs --output FILE.png") }
        do {
            let phone = IPhoneAgentScreen(screen: name)
            let frame = try phone.frame()
            let size = CGSize(width: frame.width * pixelsPerPoint, height: frame.height * pixelsPerPoint)
            let png = try phone.screenshot(size: size)
            // Written whole or not at all: a failed run leaves no file that
            // looks like this one.
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
            guard let seen = phone.observation else { fail("the screenshot recorded no observation", code: 1) }
            DriverCommands.emit(["ok": true, "output": URL(fileURLWithPath: output).path,
                                 "width": Int(seen.pixelSize.width), "height": Int(seen.pixelSize.height),
                                 "pid": Int(seen.pid), "windowID": Int(seen.windowID),
                                 "frame": ["x": seen.frame.minX, "y": seen.frame.minY,
                                           "width": seen.frame.width, "height": seen.frame.height],
                                 "geometryVersion": seen.geometryVersion,
                                 "capturedAt": ISO8601DateFormatter().string(from: seen.capturedAt)])
            exit(0)
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    private static func act(_ verb: String, screen name: String, _ args: Arguments) -> Never {
        var action: InputAction
        switch verb {
        case "tap":
            guard let x = args.value("--x").flatMap(Double.init), let y = args.value("--y").flatMap(Double.init)
            else { fail("iphone tap needs --x and --y") }
            action = InputAction(.click)
            action.x = x
            action.y = y
        case "type":
            guard let text = args.value("--text") else { fail("iphone type needs --text") }
            action = InputAction(.type)
            action.value = text
        default:
            guard let key = args.value("--key") else { fail("iphone key needs --key") }
            action = InputAction(.key)
            // Mirroring's View menu: Home Screen ⌘1, App Switcher ⌘2, Spotlight ⌘3.
            switch key.lowercased() {
            case "home": action.key = "home"
            case "switcher", "recents": action.key = "2"; action.modifiers = ["cmd"]
            case "spotlight", "search": action.key = "3"; action.modifiers = ["cmd"]
            case "enter": action.key = "return"
            default: action.key = key.lowercased()
            }
        }
        do {
            let phone = IPhoneAgentScreen(screen: name)
            let frame = try phone.frame()
            // The pixels were read off a screenshot of some window at some
            // geometry; they mean nothing on another.
            if let expected = args.value("--geometry"), let bound = phone.binding {
                let size = CGSize(width: frame.width * pixelsPerPoint, height: frame.height * pixelsPerPoint)
                let now = IPhoneObservation.geometryVersion(windowID: bound.windowID, frame: frame, pixelSize: size)
                guard now == expected else {
                    DriverCommands.emit(["ok": false, "notSent": true, "error": IPhoneError(
                        "stale_observation", reason: "moved",
                        "the window is now \(now), not the screenshot's \(expected); take a new screenshot")
                        .localizedDescription])
                    exit(1)
                }
            }
            if let x = action.x, let y = action.y {
                let point = CGPoint(x: x / pixelsPerPoint, y: y / pixelsPerPoint)
                guard point.x >= 0, point.y >= 0, point.x < frame.width, point.y < frame.height else {
                    fail("(\(Int(x)), \(Int(y))) is outside the \(Int(frame.width * pixelsPerPoint))x"
                        + "\(Int(frame.height * pixelsPerPoint)) screenshot", code: 1)
                }
                action.x = frame.minX + point.x
                action.y = frame.minY + point.y
            }
            finish(try phone.perform(action))
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }
}

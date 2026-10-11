import CoreGraphics
import Foundation
import Testing
@testable import SecondScreenCore

// #263 B-2: hover is refused at the engine's entry, before anything is read
// or sent; the middle-click hover no longer exists.
struct HoverRefusalTests {
    let window = WindowInfo(pid: 999_999, windowID: 999_999, appName: "Synthetic", title: "",
                            frame: CGRect(x: 1920, y: 25, width: 1440, height: 875))
    let screen = ScreenInfo(name: "agent", kind: .agent, displayID: 0, width: 1440, height: 900, hiDPI: true,
                            frame: Frame(CGRect(x: 1920, y: 0, width: 1440, height: 900)))

    @Test func hoverIsRefusedBeforeAnythingIsSent() async throws {
        let engine = InputEngine()
        var byPoint = InputAction(.hover)
        byPoint.x = 2400
        byPoint.y = 400
        var byIndex = InputAction(.hover)
        byIndex.index = 3
        var byText = InputAction(.hover)
        byText.text = "筛选"
        for action in [byPoint, byIndex, byText] {
            let recorder = DeliveryRecorder()
            let refusal: String? = DeliveryRecorder.$active.withValue(recorder) {
                do {
                    _ = try engine.perform(action, in: window, on: screen)
                    return nil
                } catch let e as AccessibilityError {
                    return e.message
                } catch {
                    return "\(error)"
                }
            }
            #expect(refusal == InputAction.hoverRefusal)
            #expect(recorder.state == .notPerformed, "no event, focus record or pointer move was submitted")
        }
    }

    @Test func theRefusalSaysWhyAndThatNothingWasSent() {
        let text = InputAction.hoverRefusal
        #expect(text.contains("middle-button") && text.contains("#263") && text.hasSuffix("nothing was sent"))
    }
}

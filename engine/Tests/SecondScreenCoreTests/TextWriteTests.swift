import ApplicationServices
import Testing
@testable import SecondScreenCore

struct TextWriteTests {
    @Test func acceptedWriteWithDelayedReadbackIsNeverRepeated() {
        var writes = 0
        let result = AXActions.insertOnce(selected: { writes += 1; return .success },
                                         value: { writes += 1; return .success }, confirmed: { false })
        #expect(result == .unconfirmed)
        #expect(writes == 1)
    }

    @Test func ambiguousWriteIsNeverRepeated() {
        for error: AXError in [.cannotComplete, .failure, .invalidUIElement] {
            var writes = 0
            let result = AXActions.insertOnce(selected: { writes += 1; return error },
                                             value: { writes += 1; return .success }, confirmed: { true })
            #expect(result == .unconfirmed)
            #expect(writes == 1)
        }
    }

    @Test func explicitRefusalAllowsOneAlternative() {
        var writes = 0
        let result = AXActions.insertOnce(selected: { .attributeUnsupported },
                                         value: { writes += 1; return .success }, confirmed: { true })
        #expect(result == .landed)
        #expect(writes == 1)
    }
    @Test func staleOrMissingReadbackIsUnknown() throws {
        for (before, after): (String?, String?) in [("old", "old"), (nil, "new"), ("old", nil)] {
            let recorder = DeliveryRecorder()
            DeliveryRecorder.$active.withValue(recorder) {
                recorder.note(.submitted)
                #expect(throws: AccessibilityError.self) {
                    try InputEngine.checkTypedText(before: before, after: after)
                }
            }
            #expect(recorder.state == .unknown)
        }
        try InputEngine.checkTypedText(before: "old", after: "oldnew")
    }

    @Test func bothExplicitRefusalsPerformNothing() {
        #expect(AXActions.insertOnce(selected: { .attributeUnsupported },
                                     value: { .apiDisabled }, confirmed: { true }) == .refused)
    }
}

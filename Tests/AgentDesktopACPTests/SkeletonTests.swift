import AgentDesktopContracts
import Testing
@testable import AgentDesktopACP

/// The skeleton's types build and keep their safety defaults.
@Suite struct SkeletonTests {
    @Test func privacyDefaultsAreStrictest() {
        let p = ACPPrivacyPolicy()
        #expect(p.screenshots == .off)
        let text = p.pageText
        #expect(!text)
    }

    @Test func permissionRequestsOfferOnlyOnceOptions() {
        let call = ACPToolCall(toolCallId: "t1", title: "x", kind: .other, status: .pending)
        let r = ACPPermissionRequest(sessionId: "s", toolCall: call, summary: [])
        #expect(r.options == [.allowOnce, .rejectOnce])
    }

    @Test func requestIdsCompareByValue() {
        #expect(ACPRequestId(.string("1")) == ACPRequestId(.string("1")))
        #expect(ACPRequestId(.string("1")) != ACPRequestId(.number(raw: "1", value: 1)))
    }
}

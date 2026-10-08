import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// Text and field redaction (docs/acp/08-event-mapping.md §四).
@Suite struct ETestRedactorTests {
    @Test(arguments: [
        ("Click send to candidate: example@email.com", "Click send to candidate: [邮箱]"),
        ("mailto:a.b+c@sub.example.co.uk 已发", "[邮箱] 已发"),
        ("候选人example@email.com", "候选人[邮箱]"),
        ("全角 ｅｘａｍｐｌｅ＠ｅｍａｉｌ．ｃｏｍ", "全角 [邮箱]"),
        ("电话13800138000请回电", "电话[电话]请回电"),
        ("+86 138-0013-8000", "[电话]"),
        ("+8613800138000", "[电话]"),
        ("138 0013 8000", "[电话]"),
        ("１３８００１３８０００", "[电话]"),
        ("call (555) 123-4567 now", "call [电话] now"),
        ("+1 415 555 0100", "[电话]"),
        ("座机 010-12345678", "座机 [电话]"),
        ("身份证 11010519491231002X", "身份证 [证件号]"),
        ("身份证11010519491231002x。", "身份证[证件号]。"),
        ("卡号 6222 0212 3456 7890", "卡号 [数字]"),
        ("account 1234567", "account [数字]"),
        ("old id 110105491231002", "old id [数字]"),
        ("see https://mail.example.com/inbox?id=7", "see [链接]"),
        ("see www.example.com/x", "see [链接]"),
        ("Authorization: Bearer abcdefghijklmnop", "Authorization: [凭据]"),
        ("password=hunter2 ok", "password=[凭据] ok"),
        ("密码：abc123，下一步", "密码：[凭据]，下一步"),
        ("key sk-abcdefghijklmnopqrstuv", "key [凭据]"),
        ("hex 0123456789abcdef0123456789abcdef", "hex [凭据]"),
        ("jwt eyJhbGciOi.eyJzdWIiOi.SflKxwRJSM", "jwt [凭据]"),
        ("Step 3: Submit form", "Step 3: Submit form"),
        ("点击 发送 按钮", "点击 发送 按钮"),
        ("2026-10-08 12:00", "2026-10-08 12:00"),
    ])
    func masks(_ input: String, _ expected: String) {
        #expect(ACPRedactor.redact(input) == expected)
    }

    @Test func oneLineAndBounded() {
        let s = ACPRedactor.redact("a\nb\r\nc\td\u{2028}e\u{0}f")
        #expect(!s.contains("\n") && !s.contains("\r") && !s.contains("\t") && !s.contains("\u{0}"))
        let long = ACPRedactor.redact(String(repeating: "很长的说明", count: 100))
        #expect(long.count == ACPRedactor.maxLength)
        #expect(long.hasSuffix("…"))
    }

    @Test func policyDoesNotLoosenMasks() {
        var wide = ACPPrivacyPolicy()
        wide.pageText = true
        wide.screenshots = .all
        let text = "token=abc123456 example@email.com 13800138000"
        #expect(ACPRedactor.redact(text, policy: wide) == ACPRedactor.redact(text, policy: ACPPrivacyPolicy()))
        #expect(ACPProjector().redact(text, policy: wide) == "token=[凭据] [邮箱] [电话]")
    }

    @Test func identifiers() {
        #expect(ACPRedactor.identifier("run_3fa2b1c09d8e") == "run_3fa2b1c09d8e")
        // Caller-chosen ids may carry personal data: hashed, letters only.
        let h = ACPRedactor.identifier("send-to-13800138000")
        #expect(h.hasPrefix("ref-") && h.count == 12)
        #expect(h.dropFirst(4).allSatisfy { $0.isLetter && $0.isLowercase })
        // Runtime-shaped but with a long digit run: hashed too.
        #expect(ACPRedactor.identifier("req_13800138000a").hasPrefix("ref-"))
        // Stable.
        #expect(ACPRedactor.identifier("x@y") == ACPRedactor.identifier("x@y"))
        #expect(ACPRedactor.targetReference(windowId: 813, elementRef: "el_7")
            == ACPRedactor.targetReference(windowId: 813, elementRef: "el_7"))
        #expect(ACPRedactor.targetReference(windowId: 813, elementRef: "el_7")
            != ACPRedactor.targetReference(windowId: 814, elementRef: "el_7"))
    }

    @Test func errorCodesOnlyFromTheCatalogue() {
        #expect(ACPRedactor.errorCode("stale_observation") == "stale_observation")
        #expect(ACPRedactor.errorCode("action_delivery_unknown") == "action_delivery_unknown")
        #expect(ACPRedactor.errorCode("Leaked example@email.com") == "unlisted_error")
        #expect(ACPRedactor.errorCode(nil) == "unlisted_error")
    }

    /// Every code in contracts/runtime/v1/errors.json is displayable.
    @Test func catalogueCoversRuntimeErrors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/runtime/v1/errors.json")
        let doc = try StrictJSON.parse(Data(contentsOf: url))
        let codes = (doc["codes"]?.objectMembers?.map(\.key)) ?? (doc["codes"]?.arrayValue?.compactMap { $0["code"]?.stringValue ?? $0.stringValue } ?? [])
        #expect(!codes.isEmpty)
        for c in codes { #expect(ACPRedactor.knownErrorCodes.contains(c), "missing \(c)") }
    }

    @Test func classification() {
        #expect(ACPDataClassifier.classify(key: "attachToken") == .credential)
        #expect(ACPDataClassifier.classify(key: "password") == .credential)
        #expect(ACPDataClassifier.classify(key: "text") == .typedValue)
        #expect(ACPDataClassifier.classify(key: "title") == .windowTitle)
        #expect(ACPDataClassifier.classify(key: "label") == .pageText)
        #expect(ACPDataClassifier.classify(key: "image") == .screenshot)
        #expect(ACPDataClassifier.classify(key: "pageUrl") == .url)
        #expect(ACPDataClassifier.classify(key: "delivery") == .code)
        #expect(ACPDataClassifier.classify(key: "windowId") == .scalar)
        #expect(ACPDataClassifier.classify(key: "requestId") == .identifier)
        #expect(ACPDataClassifier.classify(key: "anythingElse") == .freeText)
        #expect(ACPDataClassifier.isWithheld(.obj([("sensitive", .bool(true))])))
        #expect(ACPDataClassifier.isWithheld(.obj([("dataClassification", .string("PII"))])))
        #expect(!ACPDataClassifier.isWithheld(.obj([("label", .string("ok"))])))
    }

    @Test func jsonForLogs() {
        let payload = JSONValue.obj([
            ("requestId", .string("send-to-13800138000")),
            ("kind", .string("type")),
            ("text", .string("my secret message")),
            ("attachToken", .string(String(repeating: "a", count: 64))),
            ("title", .string("Inbox – a@b.com")),
            ("target", .obj([("label", .string("13800138000")), ("windowId", .int(813))])),
            ("screenshot", .obj([("artifactId", .string("art_3f9c1a7be2d4")), ("base64", .string("iVBORw0KGgo="))])),
            ("withheld", .obj([("sensitive", .bool(true)), ("x", .string("hidden"))])),
            ("summary", .string("sent to example@email.com")),
            ("url", .string("https://x.example.com/?token=1")),
        ])
        let out = ACPRedactor.redactJSON(payload)
        let text = out.encoded()
        for secret in ["13800138000", "my secret", "aaaaaaaa", "a@b.com", "Inbox", "iVBOR", "hidden", "example@email.com", "https://"] {
            #expect(!text.contains(secret), "leaked \(secret): \(text)")
        }
        #expect(out["kind"] == .string("type"))
        #expect(out["target"]?["windowId"] == .int(813))
        #expect(out["summary"] == .string("sent to [邮箱]"))

        var wide = ACPPrivacyPolicy()
        wide.pageText = true
        let w = ACPRedactor.redactJSON(payload, policy: wide)
        #expect(w["title"] == .string("Inbox – [邮箱]"))
        #expect(w["text"] == .string(ACPRedactMask.hidden), "typed text stays hidden under pageText")
        #expect(w["attachToken"] == .string(ACPRedactMask.hidden))
    }

    @Test func logLineIsSafe() {
        let e = ACPRuntimeEvent(runId: "run_for_example@email.com", cursor: 3, type: "Send to 13800138000",
                                payload: .obj([("message", .string("call 13800138000"))]))
        let line = ACPRedactor.logLine(e)
        #expect(ETest.leaks(in: line).isEmpty, "\(line)")
        #expect(line.contains("type=unrecognized"))
        struct Boom: Error, CustomStringConvertible { var description: String { "failed for example@email.com" } }
        #expect(ACPRedactor.logSafe(Boom()) == "failed for [邮箱]")
    }
}

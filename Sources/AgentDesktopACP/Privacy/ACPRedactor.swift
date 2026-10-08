import AgentDesktopProtocol
import Foundation

// Field-level redaction (docs/acp/08-event-mapping.md §四, plan v1.0 §6.4).
//
// The one place in the ACP adapter that decides what text may leave it.
// Other lanes call `ACPRedactor.redact` / `redactJSON` / `logLine` before
// anything reaches a log, a store or an error message.

/// The masks put in place of what was removed. Fixed strings, so tests and
/// editors can recognise them.
public enum ACPRedactMask {
    public static let email = "[邮箱]"
    public static let phone = "[电话]"
    public static let idNumber = "[证件号]"
    public static let digits = "[数字]"
    public static let url = "[链接]"
    public static let credential = "[凭据]"
    public static let hidden = "[已隐藏]"
}

public enum ACPRedactor {
    /// Longest free-text string that may leave the projector.
    public static let maxLength = 160

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static func rule(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> Rule {
        // The patterns are constants; a bad one is a programming error caught by the tests.
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template)
    }

    // Order matters: credentials and links first (they may contain digits
    // and @), then e-mail, ID numbers, phones, and finally any digit run.
    private static let credentialRules: [Rule] = [
        rule(#"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,}"#, ACPRedactMask.credential),
        rule(#"(?i)(password|passwd|pwd|passcode|secret|token|api[_-]?key|access[_-]?key|authorization|cookie|session[_-]?id|otp|密码|口令|验证码|令牌|密钥)(\s*[:=：]\s*)[^\s,，;；]+"#,
             "$1$2" + ACPRedactMask.credential),
        rule(#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#, ACPRedactMask.credential),
        rule(#"\b(?:sk|pk|rk|ghp|gho|ghs|ghu|github_pat|xox[abprs]|AKIA|ASIA)[-_A-Za-z0-9]{10,}"#, ACPRedactMask.credential),
        rule(#"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#, ACPRedactMask.credential),
        rule(#"(?<![A-Za-z0-9+/_=-])(?=[A-Za-z0-9+/_-]*[0-9])(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{40,}={0,2}"#, ACPRedactMask.credential),
    ]
    private static let linkRules: [Rule] = [
        rule(#"(?i)\b(?:https?|ftp|file|wss?|smb|afp)://[^\s<>"'，。；、）)\]]+"#, ACPRedactMask.url),
        rule(#"(?i)\bwww\.[^\s<>"'，。；、）)\]]+"#, ACPRedactMask.url),
    ]
    private static let emailRules: [Rule] = [
        rule(#"(?i)(?:mailto:)?[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, ACPRedactMask.email),
        // An address with a bare host ("a@localhost") is still an address.
        rule(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]{2,}"#, ACPRedactMask.email),
    ]
    private static let digitRules: [Rule] = [
        // PRC resident ID: 18 characters with a birth date, last may be X.
        rule(#"(?<![0-9A-Za-z])[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?![0-9A-Za-z])"#,
             ACPRedactMask.idNumber),
        // Chinese mobile, optionally +86, with spaces or dashes.
        rule(#"(?<![0-9])(?:\+?86[\s-]?)?1[3-9]\d[\s-]?\d{4}[\s-]?\d{4}(?![0-9])"#, ACPRedactMask.phone),
        // International with a leading +.
        rule(#"(?<![0-9A-Za-z])\+\d{1,3}[\s.-]?\(?\d{1,4}\)?(?:[\s.-]?\d{2,4}){2,4}(?![0-9])"#, ACPRedactMask.phone),
        // (555) 123-4567, 555-123-4567, 555.123.4567
        rule(#"(?<![0-9])\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?![0-9])"#, ACPRedactMask.phone),
        // Chinese landline 010-12345678, 0755-1234567
        rule(#"(?<![0-9])0\d{2,3}-\d{7,8}(?![0-9])"#, ACPRedactMask.phone),
        // Card-like groups: 6222 0212 3456 7890
        rule(#"(?<![0-9])\d{4}(?:[\s-]\d{4}){2,4}(?![0-9])"#, ACPRedactMask.digits),
        // Any other run of 7 or more digits (bank cards, 15-digit IDs, QQ, accounts).
        rule(#"(?<![0-9])\d{7,}(?![0-9])"#, ACPRedactMask.digits),
    ]

    private static func apply(_ rules: [Rule], _ text: String) -> String {
        var s = text
        for r in rules {
            s = r.regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r.template)
        }
        return s
    }

    /// Full-width digits, letters, @, +, - and . become ASCII so that the
    /// patterns see them (Chinese punctuation such as ：（） is kept); line
    /// breaks and control characters become spaces so a redacted string is
    /// always one display or log line.
    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = false
        for var u in text.unicodeScalars {
            switch u.value {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF20, 0xFF0B, 0xFF0D, 0xFF0E:
                u = Unicode.Scalar(u.value - 0xFEE0)!
            default: break
            }
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(u) || CharacterSet.controlCharacters.contains(u)
                || u.properties.generalCategory == .format
            if isSpace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(u); lastSpace = false
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    static func truncate(_ s: String) -> String {
        s.count <= maxLength ? s : String(s.prefix(maxLength - 1)) + "…"
    }

    /// Mask every personal or secret pattern in free text. Policy-independent:
    /// opting in to page text widens *which fields* are shown, never what a
    /// shown field may contain.
    public static func redact(_ text: String) -> String {
        var s = normalize(text)
        s = apply(credentialRules, s)
        s = apply(linkRules, s)
        s = apply(emailRules, s)
        s = apply(digitRules, s)
        return truncate(s)
    }

    /// `ACPEventProjector.redact` semantics: same masks under every policy.
    public static func redact(_ text: String, policy: ACPPrivacyPolicy) -> String {
        redact(text)
    }

    /// Last pass over strings composed by the projector itself: removes
    /// anything that slipped into a composed line (links, addresses,
    /// credentials). Digit rules stay at field level, so Run ids survive.
    static func guardOutput(_ text: String) -> String {
        var s = normalize(text)
        s = apply(credentialRules, s)
        s = apply(linkRules, s)
        s = apply(emailRules, s)
        return s
    }

    // MARK: Identifiers

    /// Runtime-generated ids look like `run_3fa2b1c09d8e`; those carry no
    /// personal data and are shown as they are, so a person can match them
    /// with the main window. Anything else (caller-chosen request ids,
    /// element refs) is shown as a stable letters-only hash.
    public static func identifier(_ raw: String) -> String {
        if raw.range(of: #"^[a-z]{2,8}_[0-9a-f]{8,32}$"#, options: .regularExpression) != nil,
           raw.range(of: #"[0-9]{7,}"#, options: .regularExpression) == nil {
            return raw
        }
        return "ref-" + hashLetters(raw)
    }

    /// A short opaque reference for a target, never its coordinates or label.
    public static func targetReference(windowId: Int?, elementRef: String?) -> String {
        "ref-" + hashLetters("w\(windowId.map(String.init) ?? "?")/\(elementRef ?? "-")")
    }

    /// FNV-1a 64 → 8 letters a–z. Letters only, so no digit rule ever
    /// touches it and it cannot spell a number.
    static func hashLetters(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var out = ""
        for _ in 0..<8 { out.append(letters[Int(h % 26)]); h /= 26 }
        return out
    }

    // MARK: Codes

    /// Error codes that are safe to show: the runtime/1 catalogue
    /// (contracts/runtime/v1/errors.json) plus the receipt axes.
    public static let knownErrorCodes: Set<String> = [
        "invalid_argument", "schema_invalid", "frame_too_large", "not_found", "invalid_target", "runtime_offline",
        "permission_denied", "ownership_escalation_denied", "approval_required", "control_busy", "stale_observation",
        "idempotency_conflict", "conflict", "run_not_active", "input_disabled", "stop_pending", "handshake_required",
        "version_mismatch", "instance_mismatch", "capability_missing", "model_unavailable", "execution_failed",
        "internal_error", "limit_exceeded", "events_cursor_expired", "wait_timeout", "deadline_exceeded",
        "pairing_required", "client_revoked", "grant_missing", "grant_expired", "permit_expired", "target_moved",
        "audit_unavailable", "unsupported_backend", "capability_mismatch", "connection_lost",
        "request_acceptance_unknown", "action_delivery_unknown", "cancel_acceptance_unknown",
        "not_dispatched", "policy_rejected", "approval_denied", "approval_unavailable",
    ]

    /// A code from the catalogue, or `unlisted_error`. Never free text.
    public static func errorCode(_ raw: String?) -> String {
        guard let raw, knownErrorCodes.contains(raw) else { return "unlisted_error" }
        return raw
    }

    /// An event type name if it has the catalogue's shape, else nil.
    public static func eventTypeName(_ raw: String) -> String? {
        raw.range(of: #"^[a-z][a-z_]{0,31}(\.[a-z][a-z_]{0,31}){1,3}$"#, options: .regularExpression) != nil ? raw : nil
    }

    // MARK: JSON and logs

    /// Redact a whole payload by field class, for logs and stores. Ids and
    /// codes stay, free text is masked, everything never-shown is replaced
    /// by `[已隐藏]`. Never returns screenshot bytes, typed values,
    /// credentials or window titles, whatever the policy.
    public static func redactJSON(_ value: JSONValue, policy: ACPPrivacyPolicy = ACPPrivacyPolicy()) -> JSONValue {
        redactJSON(value, as: .freeText, policy: policy)
    }

    private static func redactJSON(_ value: JSONValue, as cls: ACPDataClass, policy: ACPPrivacyPolicy) -> JSONValue {
        switch cls {
        case .credential, .typedValue, .screenshot, .withheld, .windowTitle, .identity:
            return value.isNull ? .null : .string(ACPRedactMask.hidden)
        case .pageText:
            if !policy.pageText { return value.isNull ? .null : .string(ACPRedactMask.hidden) }
        case .url:
            return value.isNull ? .null : .string(ACPRedactMask.url)
        default: break
        }
        switch value {
        case let .object(members):
            if ACPDataClassifier.isWithheld(value) { return .string(ACPRedactMask.hidden) }
            return .object(members.map { m in
                (key: m.key, value: redactJSON(m.value, as: ACPDataClassifier.classify(key: m.key), policy: policy))
            })
        case let .array(items):
            return .array(items.map { redactJSON($0, as: cls, policy: policy) })
        case let .string(s):
            switch cls {
            // Free text can quote a window title or a name, which no pattern
            // finds (ruling P1): logs and stores keep codes and ids only.
            case .freeText: return .string(ACPRedactMask.hidden)
            case .identifier: return .string(identifier(s))
            case .code: return .string(s.range(of: #"^[a-z][a-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil ? s : redact(s))
            case .scalar: return .string(redact(s))
            default: return .string(redact(s))
            }
        default:
            return value
        }
    }

    /// One log line for a Runtime event: ids, cursor, type and a redacted
    /// payload. Safe for debug logs and crash reports.
    public static func logLine(_ event: ACPRuntimeEvent) -> String {
        let type = eventTypeName(event.type) ?? "unrecognized"
        return "run=\(identifier(event.runId)) cursor=\(event.cursor) type=\(type) data=\(redactJSON(event.payload).encoded())"
    }

    /// An error for logs: its catalogue code, never its message (a Runtime
    /// message can name another app's window or a person; ruling P1).
    public static func logSafe(_ error: Error) -> String {
        if let e = error as? ACPError { return "error code=\(e.code) reason=\(errorCode(e.reason))" }
        let type = String(describing: Swift.type(of: error))
        return "error type=" + (type.range(of: #"^[A-Za-z_][A-Za-z0-9_.<>]{0,63}$"#, options: .regularExpression) != nil ? type : "unrecognized")
    }
}

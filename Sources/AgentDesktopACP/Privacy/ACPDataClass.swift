import AgentDesktopProtocol
import Foundation

// Data classification for Runtime payload fields (docs/acp/08-event-mapping.md §二、§四).
//
// Every field of a Runtime event is put in one class by its key before any
// of it may be shown. The class, not the event type, decides whether a
// value can reach an editor, a log or a store.

/// Kevin's three display tiers (docs/acp/README.md §五 constraint 3), for
/// events (`ACPEventType.tier`) and for fields (`ACPDataClass.tier`).
public enum ACPEventTier: String, Sendable, CaseIterable {
    /// Fully displayable: closed vocabularies, ids, counts. Run lifecycle.
    case normal
    /// Displayable only after redaction, and only what the policy opts in.
    /// Actions: category, status, timing, a hashed target; titles and labels
    /// of the bound target under `pageText`; a screenshot reference under
    /// `screenshots`.
    case sensitive
    /// Status only, never content, under every policy: typed input,
    /// credentials, approval parameters, questions, screenshot bytes,
    /// anything withheld, and event types outside the catalogue.
    case protected
}

/// What a field holds, from the most to the least shareable.
public enum ACPDataClass: String, Sendable, CaseIterable {
    /// Closed vocabularies: kind, phase, outcome, delivery, error codes.
    case code
    /// Opaque ids (runId, requestId, elementRef). Shown only through
    /// `ACPRedactor.identifier`.
    case identifier
    /// Counts, flags, timestamps, revisions.
    case scalar
    /// Free text written by a program or a person: titles of actions,
    /// summaries, error messages. Never shown by default.
    case freeText
    /// Window titles. Never shown, under any policy, and hidden in logs and
    /// stores (Kevin's ruling P1: identity data, main window only).
    case windowTitle
    /// Who someone is: names, accounts, app or process names, senders and
    /// recipients. Never shown, under any policy (ruling P1).
    case identity
    /// Text read from the target app: element labels and values, OCR.
    /// Never shown by default; `pageText` widens.
    case pageText
    /// What an action typed or pasted. Never shown, under any policy.
    case typedValue
    /// Links. Never shown verbatim.
    case url
    /// Screenshot references or bytes. Bytes never; references by policy.
    case screenshot
    /// Passwords, tokens, cookies, keys. Never shown, under any policy.
    case credential
    /// The Runtime marked it sensitive or withheld it. Never shown.
    case withheld
}

extension ACPDataClass {
    public var tier: ACPEventTier {
        switch self {
        case .code, .identifier, .scalar: return .normal
        case .freeText, .pageText, .url: return .sensitive
        case .windowTitle, .identity, .typedValue, .screenshot, .credential, .withheld: return .protected
        }
    }
}

/// Field name → class. Unknown string fields are `freeText` (strict).
public enum ACPDataClassifier {
    static func norm(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static let credentialKeys: Set<String> = [
        "password", "passwd", "pwd", "passcode", "secret", "clientsecret", "token", "attachtoken", "accesstoken",
        "refreshtoken", "idtoken", "sessiontoken", "bearer", "apikey", "accesskey", "privatekey", "authorization",
        "auth", "cookie", "cookies", "setcookie", "credential", "credentials", "otp", "pin", "signature",
    ]
    static let typedKeys: Set<String> = ["text", "typed", "typedtext", "input", "inputtext", "clipboard", "paste", "keys"]
    /// Approval and action parameters: what an action would do, verbatim.
    static let parameterKeys: Set<String> = ["params", "parameters", "arguments", "args", "actionparams", "approvalparams", "rawaction"]
    /// Facts about windows other than the bound target (G0 refusals name the
    /// covering window): cross-app data.
    static let otherWindowPrefixes = ["covering", "other", "foreign", "sibling"]
    static let windowTitleKeys: Set<String> = ["title", "windowtitle", "documenttitle", "tabtitle"]
    static let identityKeys: Set<String> = [
        "name", "displayname", "username", "fullname", "realname", "nickname", "appname", "processname", "bundlename",
        "account", "accountname", "contact", "contactname", "sender", "recipient", "from", "to", "cc", "owner",
        "candidate", "person", "author",
    ]
    static let pageTextKeys: Set<String> = [
        "label", "value", "elements", "matches", "pagetext", "content", "ocr", "accessibilitylabel",
        "accessibilityvalue", "placeholder", "selectedtext", "html", "dom",
    ]
    static let urlKeys: Set<String> = ["url", "href", "link", "uri", "location", "pageurl"]
    static let screenshotKeys: Set<String> = ["image", "screenshot", "png", "jpeg", "imagedata", "thumbnail", "pixels", "bytes", "base64"]
    static let freeTextKeys: Set<String> = [
        "message", "summary", "description", "goal", "detail", "details", "note", "prompt",
        "instruction", "instructions", "step", "reasontext", "explanation",
    ]
    static let codeKeys: Set<String> = [
        "type", "kind", "phase", "outcome", "quiescence", "delivery", "execution", "verification", "businessresult",
        "lifetime", "origin", "ownership", "code", "reason", "route", "mediatype", "status", "mode", "button",
        "direction", "modifiers", "result", "level", "tasktype", "unittype", "action",
    ]
    static let scalarKeys: Set<String> = [
        "sequence", "cursor", "revision", "generation", "inflight", "count", "amount", "index", "total", "width",
        "height", "bytesize", "unknownactions", "elapsedms", "at", "acceptedat", "dispatchedat", "completedat",
        "startedat", "endedat", "createdat", "x", "y", "pid", "windowid", "alreadyterminal", "stepindex", "stepcount",
    ]

    /// The class of the value stored under `key`.
    public static func classify(key: String) -> ACPDataClass {
        let k = norm(key)
        if credentialKeys.contains(k) || k.hasSuffix("token") || k.hasSuffix("secret") || k.hasSuffix("password")
            || k.hasSuffix("apikey") || k.hasSuffix("cookie") {
            return .credential
        }
        if typedKeys.contains(k) || parameterKeys.contains(k) { return .typedValue }
        if otherWindowPrefixes.contains(where: { k.hasPrefix($0) }) { return .withheld }
        if windowTitleKeys.contains(k) { return .windowTitle }
        if identityKeys.contains(k) { return .identity }
        if screenshotKeys.contains(k) { return .screenshot }
        if pageTextKeys.contains(k) { return .pageText }
        if urlKeys.contains(k) || k.hasSuffix("url") { return .url }
        if codeKeys.contains(k) { return .code }
        if scalarKeys.contains(k) { return .scalar }
        if k.hasSuffix("id") || k.hasSuffix("ref") || k.hasSuffix("ids") { return .identifier }
        if freeTextKeys.contains(k) { return .freeText }
        return .freeText
    }

    /// The Runtime marks an object withheld or sensitive (schema
    /// `sensitive` / `withheld` flags, or a sensitive `dataClassification`).
    public static func isWithheld(_ object: JSONValue) -> Bool {
        if object["sensitive"]?.boolValue == true || object["withheld"]?.boolValue == true { return true }
        if object["redacted"]?.boolValue == true { return true }
        if let c = object["dataClassification"]?.stringValue?.lowercased(),
           ["sensitive", "confidential", "pii", "personal", "secret", "restricted"].contains(c) {
            return true
        }
        return false
    }
}

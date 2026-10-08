import Foundation

/// One decoded WDA answer: `{"value": ..., "sessionId": ...}` (W3C) or the
/// legacy `{"status": n, "value": ...}` shape.
struct WDAAnswer {
    let httpStatus: Int
    let value: Any?
    let sessionId: String?
    /// W3C `value.error`, or the legacy numeric status as a string.
    let errorCode: String?
    let errorMessage: String?

    var isError: Bool { errorCode != nil || httpStatus >= 400 }

    static func decode(httpStatus: Int, data: Data) -> WDAAnswer? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = object as? [String: Any] else {
            return nil
        }
        let value = root["value"]
        let sessionId = root["sessionId"] as? String
        var code: String?
        var message: String?
        if let dict = value as? [String: Any], let error = dict["error"] as? String {
            code = error
            message = dict["message"] as? String
        } else if let status = root["status"] as? Int, status != 0 {
            code = String(status)
            message = (value as? [String: Any])?["message"] as? String ?? value as? String
        }
        return WDAAnswer(httpStatus: httpStatus, value: value, sessionId: sessionId,
                         errorCode: code, errorMessage: message)
    }
}

enum WDAErrorMapping {
    /// W3C error codes and legacy JSONWP statuses, mapped to a kind and to
    /// whether the command can have run.
    static func classify(code: String?, httpStatus: Int, isAction: Bool) -> (WDAErrorKind, WDADeliveryState) {
        switch code {
        case "invalid session id", "6":
            return (.sessionInvalid, .rejected)
        case "no such element", "stale element reference", "7", "10":
            return (.elementNotFound, .rejected)
        case "unknown command", "unknown method", "9":
            return (.unsupportedEndpoint, .rejected)
        case "invalid argument", "61":
            return (.invalidArgument, .rejected)
        case "timeout", "script timeout", "21", "28":
            return (.timeout, isAction ? .unknown : .rejected)
        default:
            if code == nil, httpStatus == 404 { return (.unsupportedEndpoint, .rejected) }
            // An unclassified error in the middle of a gesture or typing may
            // follow partial input.
            return (.wdaRejected, isAction ? .unknown : .rejected)
        }
    }

    /// URLError codes that prove nothing was sent.
    static let refusedBeforeSending: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet, .badURL, .unsupportedURL,
    ]
}

/// Width and height from a PNG's IHDR chunk, without image frameworks.
enum PNGHeader {
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24, Array(data.prefix(8)) == signature else { return nil }
        let bytes = [UInt8](data[data.startIndex + 16 ..< data.startIndex + 24])
        let width = bytes[0 ..< 4].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[4 ..< 8].reduce(0) { $0 << 8 | Int($1) }
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

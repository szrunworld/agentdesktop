import AgentDesktopContracts
import Foundation

/// Endpoint rules of spec §10.1.
public enum EndpointPolicy {
    /// Validate a configured base URL and return it normalized with exactly
    /// one trailing slash. HTTP is allowed only to a loopback host and only
    /// when `allowLoopbackHTTP` is on; `localhost` must actually resolve to
    /// loopback addresses.
    public static func normalize(_ raw: String, allowLoopbackHTTP: Bool,
                                 resolve: (String) -> [String] = resolveHost) throws -> URL {
        func refuse(_ why: String) -> ContractError {
            ContractError(.validationError, why, details: .obj([("field", .string("baseUrl"))]))
        }
        guard let comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else {
            throw refuse("baseUrl is not an absolute URL")
        }
        guard comps.user == nil, comps.password == nil else { throw refuse("baseUrl must not contain credentials") }
        guard comps.query == nil else { throw refuse("baseUrl must not contain a query") }
        guard comps.fragment == nil else { throw refuse("baseUrl must not contain a fragment") }
        switch scheme {
        case "https":
            break
        case "http":
            let h = host.lowercased()
            let loopbackLiteral = h == "127.0.0.1" || h == "::1" || h == "[::1]"
            guard loopbackLiteral || h == "localhost" else {
                throw refuse("http is allowed only for 127.0.0.1, [::1] or localhost")
            }
            guard allowLoopbackHTTP else { throw refuse("local http endpoints are turned off") }
            if h == "localhost" {
                let addrs = resolve(h)
                guard !addrs.isEmpty, addrs.allSatisfy(isLoopback) else {
                    throw refuse("localhost does not resolve only to loopback addresses")
                }
            }
        default:
            throw refuse("baseUrl must use https")
        }
        var path = comps.percentEncodedPath
        while path.hasSuffix("//") { path.removeLast() }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed.lowercased().hasSuffix("/chat/completions") || trimmed.lowercased() == "chat/completions" {
            throw refuse("baseUrl must stop before /chat/completions, e.g. https://host/v1")
        }
        var out = comps
        out.percentEncodedPath = trimmed + "/"
        guard let url = out.url else { throw refuse("baseUrl is not an absolute URL") }
        return url
    }

    /// `<base>/chat/completions`, keeping any base path such as /v1/ or /api/v3/.
    public static func chatCompletionsURL(base: URL) -> URL {
        URL(string: "chat/completions", relativeTo: base)!.absoluteURL
    }

    public static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1"
    }

    public static func resolveHost(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p = res
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}

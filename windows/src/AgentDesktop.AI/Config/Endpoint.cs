using System.Net;
using System.Net.Sockets;
using AgentDesktop.Contracts;

namespace AgentDesktop.AI.Config;

/// <summary>Endpoint rules of spec §10.1, identical to the Swift EndpointPolicy.</summary>
public static class EndpointPolicy
{
    /// <summary>
    /// Validate a configured base URL and return it with exactly one trailing
    /// slash. HTTP is allowed only to a loopback host and only when
    /// <paramref name="allowLoopbackHttp"/> is on; localhost must actually
    /// resolve to loopback addresses.
    /// </summary>
    public static Uri Normalize(string raw, bool allowLoopbackHttp, Func<string, IReadOnlyList<string>>? resolve = null)
    {
        static ContractError Refuse(string why) => new(ErrorCode.ValidationError, why, details: JsonValue.Obj(
            ("fieldErrors", JsonValue.Array([JsonValue.Obj(("path", JsonValue.String("/params/baseUrl")), ("code", JsonValue.String("invalid")))]))));

        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)
            || !raw.Contains("://", StringComparison.Ordinal))
            throw Refuse("baseUrl is not an absolute URL");
        if (uri.UserInfo.Length > 0) throw Refuse("baseUrl must not contain credentials");
        if (raw.Contains('?', StringComparison.Ordinal)) throw Refuse("baseUrl must not contain a query");
        if (raw.Contains('#', StringComparison.Ordinal)) throw Refuse("baseUrl must not contain a fragment");
        switch (uri.Scheme)
        {
            case "https":
                break;
            case "http":
                var h = uri.Host.ToLowerInvariant();
                var literal = h is "127.0.0.1" or "::1" or "[::1]";
                if (!literal && h != "localhost") throw Refuse("http is allowed only for 127.0.0.1, [::1] or localhost");
                if (!allowLoopbackHttp) throw Refuse("local http endpoints are turned off");
                if (h == "localhost")
                {
                    var addrs = (resolve ?? ResolveHost)(h);
                    if (addrs.Count == 0 || !addrs.All(IsLoopback))
                        throw Refuse("localhost does not resolve only to loopback addresses");
                }
                break;
            default:
                throw Refuse("baseUrl must use https");
        }
        var path = uri.AbsolutePath;
        while (path.EndsWith("//", StringComparison.Ordinal)) path = path[..^1];
        var trimmed = path.EndsWith('/') ? path[..^1] : path;
        if (trimmed.EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase)
            || trimmed.Equals("chat/completions", StringComparison.OrdinalIgnoreCase))
            throw Refuse("baseUrl must stop before /chat/completions, e.g. https://host/v1");
        var authority = uri.GetLeftPart(UriPartial.Authority);
        return new Uri(authority + trimmed + "/");
    }

    /// <summary>&lt;base&gt;/chat/completions, keeping any base path such as /v1/ or /api/v3/.</summary>
    public static Uri ChatCompletionsUrl(Uri baseUrl) => new(baseUrl, "chat/completions");

    public static bool IsLoopback(string address) =>
        IPAddress.TryParse(address, out var ip) && IPAddress.IsLoopback(ip);

    public static IReadOnlyList<string> ResolveHost(string host)
    {
        try
        {
            return Dns.GetHostAddresses(host).Select(a => a.ToString()).ToList();
        }
        catch (SocketException)
        {
            return [];
        }
    }
}

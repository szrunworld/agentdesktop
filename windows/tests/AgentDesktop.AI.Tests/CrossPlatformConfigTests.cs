using AgentDesktop.AI.Config;
using AgentDesktop.Contracts;
using Xunit;

namespace AgentDesktop.AI.Tests;

// Fixtures/cross-platform-config.json: the same configuration script the
// Swift service runs (Tests/AgentDesktopAITests), with the same outcomes.
public class CrossPlatformConfigTests
{
    private static JsonValue Fixture() =>
        StrictJson.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "cross-platform-config.json")));

    private static JsonValue? At(JsonValue v, string dotted)
    {
        JsonValue? cur = v;
        foreach (var part in dotted.Split('.'))
        {
            if (cur is null || cur.Kind != JsonKind.Object) return null;
            cur = cur[part];
        }
        return cur;
    }

    private static JsonValue Substitute(JsonValue v, Dictionary<string, JsonValue> saved)
    {
        switch (v.Kind)
        {
            case JsonKind.String:
                var s = v.StringValue!;
                if (s.StartsWith("${", StringComparison.Ordinal) && s.EndsWith('}'))
                {
                    var path = s[2..^1];
                    var dot = path.IndexOf('.', StringComparison.Ordinal);
                    var name = path[..dot];
                    return At(saved[name], path[(dot + 1)..]) ?? throw new InvalidOperationException($"nothing at {s}");
                }
                return v;
            case JsonKind.Array:
                return JsonValue.Array(v.ArrayValue!.Select(x => Substitute(x, saved)));
            case JsonKind.Object:
                return JsonValue.Object(v.ObjectMembers!.Select(m => new KeyValuePair<string, JsonValue>(m.Key, Substitute(m.Value, saved))));
            default:
                return v;
        }
    }

    [Fact]
    public async Task ScriptHasTheSameOutcomes()
    {
        var fixture = Fixture();
        using var h = new Harness(new ConfigOptions(AllowLoopbackHttp: true));
        var routers = new Dictionary<string, RpcRouter>
        {
            ["owner"] = h.Router,
            ["other"] = new RpcRouter(h.Service.Handlers("other")),
        };
        var saved = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
        var secrets = new HashSet<string>(StringComparer.Ordinal);
        var steps = fixture["steps"]!.ArrayValue!;
        Assert.True(steps.Count >= 30);
        foreach (var step in steps)
        {
            var name = step["name"]!.StringValue!;
            var @params = Substitute(step["params"]!, saved);
            if (@params["credential"]?["apiKey"]?.StringValue is { } secret) secrets.Add(secret);
            var router = routers[step["caller"]?.StringValue ?? "owner"];
            var response = await h.Call(step["command"]!.StringValue!, @params, step["key"]?.StringValue, router);
            var expect = Substitute(step["expect"]!, saved);
            var ok = expect["ok"]!.BoolValue!.Value;
            Assert.True(response["ok"]?.BoolValue == ok, $"{name}: {response.Encoded()}");
            foreach (var s in secrets) Assert.DoesNotContain(s, response.Encoded(), StringComparison.Ordinal);
            if (ok)
            {
                var result = response["result"]!;
                foreach (var f in expect["fields"]?.ObjectMembers ?? [])
                    Assert.True(At(result, f.Key) == f.Value, $"{name}: {f.Key} is {At(result, f.Key)?.Encoded() ?? "missing"}, expected {f.Value.Encoded()}");
                foreach (var f in expect["notEqual"]?.ObjectMembers ?? [])
                    Assert.True(At(result, f.Key) != f.Value, $"{name}: {f.Key} should differ from {f.Value.Encoded()}");
                if (expect["itemCount"]?.IntValue is { } n) Assert.Equal(n, result["items"]!.ArrayValue!.Count);
                if (expect["save"]?.StringValue is { } key) saved[key] = result;
            }
            else
            {
                var error = response["error"]!;
                Assert.True(error["code"]?.StringValue == expect["code"]!.StringValue, $"{name}: got {error.Encoded()}");
                foreach (var d in expect["details"]?.ObjectMembers ?? [])
                    Assert.True(error["details"]?[d.Key] == d.Value, $"{name}: details.{d.Key} in {error.Encoded()}");
                var paths = error["details"]?["fieldErrors"]?.ArrayValue?.Select(x => x["path"]?.StringValue).ToHashSet() ?? [];
                foreach (var p in expect["fieldErrorPaths"]?.ArrayValue ?? [])
                    Assert.True(paths.Contains(p.StringValue), $"{name}: missing fieldError {p.StringValue} in {error.Encoded()}");
            }
        }
    }
}

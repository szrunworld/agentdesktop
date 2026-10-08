using AgentDesktop.AI.Config;
using AgentDesktop.Contracts;
using Xunit;

namespace AgentDesktop.AI.Tests;

public sealed class TestClock : IConfigClock
{
    private readonly Lock _lock = new();
    private DateTimeOffset _t = DateTimeOffset.FromUnixTimeSeconds(1_791_500_000);
    public DateTimeOffset Now() { lock (_lock) return _t; }
    public void Advance(double seconds) { lock (_lock) _t = _t.AddSeconds(seconds); }
}

/// <summary>Runs only on Windows; skipped elsewhere with the reason shown.</summary>
public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) Skip = "DPAPI and Windows ACLs exist only on Windows (run by the windows-latest CI job)";
    }
}

public sealed class NonWindowsFactAttribute : FactAttribute
{
    public NonWindowsFactAttribute()
    {
        if (OperatingSystem.IsWindows()) Skip = "checks the refusal on non-Windows platforms";
    }
}

/// <summary>A configuration store with its service behind a real RpcRouter, as a caller sees it.</summary>
public sealed class Harness : IDisposable
{
    public string Dir { get; }
    public string DbPath { get; }
    public InMemoryCredentialStore Creds { get; }
    public TestClock Clock { get; }
    public ConfigOptions Options { get; }
    public ConfigStore Store { get; }
    public ConfigApplicationService Service { get; }
    public RpcRouter Router { get; }
    public List<string> Responses { get; } = [];
    private readonly bool _ownsDir;

    public Harness(ConfigOptions? options = null, InMemoryCredentialStore? creds = null, string? dir = null, TestClock? clock = null)
    {
        _ownsDir = dir is null;
        Dir = dir ?? Path.Combine(Path.GetTempPath(), "adcfg-cs-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Dir);
        DbPath = Path.Combine(Dir, "config.sqlite");
        Creds = creds ?? new InMemoryCredentialStore();
        Clock = clock ?? new TestClock();
        Options = options ?? new ConfigOptions(AllowLoopbackHttp: true);
        Store = new ConfigStore(DbPath, Creds, Enumerable.Repeat((byte)7, 32).ToArray(), Clock, Options);
        Service = new ConfigApplicationService(Store);
        Router = new RpcRouter(Service.Handlers("owner"));
    }

    /// <summary>A second store over the same files: a restarted host.</summary>
    public Harness Reopened(ConfigOptions? options = null) => new(options ?? Options, Creds, Dir, Clock);

    public void Dispose()
    {
        Store.Dispose();
        if (_ownsDir)
        {
            try { Directory.Delete(Dir, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    public async Task<JsonValue> Call(string command, JsonValue? @params = null, string? key = null, RpcRouter? router = null)
    {
        var m = new List<(string, JsonValue)>
        {
            ("schemaVersion", JsonValue.String("agentdesktop.ai/1")), ("requestId", JsonValue.String(Guid.NewGuid().ToString())),
            ("command", JsonValue.String(command)), ("params", @params ?? JsonValue.Obj()),
        };
        var op = ContractBundle.Shared.Operation(command)!;
        if (op.RequiresIdempotencyKey || key is not null)
            m.Add(("context", JsonValue.Obj(("idempotencyKey", JsonValue.String(key ?? "k-" + Guid.NewGuid().ToString("N"))))));
        var output = await (router ?? Router).RespondToBody(JsonValue.Obj([.. m]).EncodedBytes());
        lock (Responses) Responses.Add(System.Text.Encoding.UTF8.GetString(output));
        Assert.Equal(0x0A, output[^1]);
        var response = StrictJson.Parse(output[..^1]);
        Assert.Empty(ContractBundle.Shared.ValidateRpc(response, "Response"));
        return response;
    }

    /// <summary>The result of a successful call, checked against &lt;command&gt;_result.</summary>
    public async Task<JsonValue> Ok(string command, JsonValue? @params = null, string? key = null)
    {
        var v = await Call(command, @params, key);
        Assert.True(v["ok"]?.BoolValue == true, $"{command} failed: {v.Encoded()}");
        var r = v["result"]!;
        Assert.Empty(ContractBundle.Shared.ValidateRpc(r, $"{ContractBundle.Shared.Operation(command)!.DefPrefix}_result"));
        return r;
    }

    public async Task<string?> Err(string command, JsonValue? @params = null, string? key = null)
    {
        var v = await Call(command, @params, key);
        Assert.True(v["ok"]?.BoolValue == false, $"{command} should fail");
        return v["error"]?["code"]?.StringValue;
    }

    public Task<JsonValue> CreateConnection(string name = "Ark", string apiKey = "sk-test-0001",
                                            string url = "https://ark.cn-beijing.volces.com/api/v3", string? key = null) =>
        Ok("ai.connections.create", ConnectionParams(name, apiKey, url), key);

    public static JsonValue ConnectionParams(string name = "Ark", string apiKey = "sk-test-0001",
                                             string url = "https://ark.cn-beijing.volces.com/api/v3") => JsonValue.Obj(
        ("name", JsonValue.String(name)), ("protocol", JsonValue.String("openai_chat")), ("baseUrl", JsonValue.String(url)),
        ("timeoutMs", JsonValue.Int(30000)), ("credential", JsonValue.Obj(("apiKey", JsonValue.String(apiKey)))));

    public Task<JsonValue> CreateModel(JsonValue conn, string modelId = "doubao-seed-2-1-lite-260915") =>
        Ok("ai.modelProfiles.create", JsonValue.Obj(
            ("name", JsonValue.String("Seed lite")), ("connectionId", conn["connectionId"]!),
            ("connectionRevision", conn["revision"]!), ("modelId", JsonValue.String(modelId)),
            ("requestOptions", JsonValue.Obj(("temperature", JsonValue.Int(0)), ("seed", JsonValue.Int(7)))),
            ("maxOutputTokens", JsonValue.Int(1024))));

    public static readonly JsonValue Limits = JsonValue.Obj(
        ("maxSteps", JsonValue.Int(20)), ("maxWallTimeMs", JsonValue.Int(120000)), ("maxModelAttemptsPerStep", JsonValue.Int(2)),
        ("maxTotalModelAttempts", JsonValue.Int(30)), ("maxOutputTokens", JsonValue.Int(1024)), ("maxWaitMs", JsonValue.Int(5000)),
        ("maxScreenshots", JsonValue.Int(5)), ("maxImageEncodedBytes", JsonValue.Int(8_388_608)), ("requireReportedUsage", JsonValue.Bool(false)));

    public static JsonValue GuiParams(JsonValue model, string name = "UI-TARS", JsonValue[]? fallback = null, string adapter = "uitars_v1") =>
        JsonValue.Obj(
            ("name", JsonValue.String(name)), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
            ("adapterId", JsonValue.String(adapter)), ("adapterVersion", JsonValue.String("1")), ("promptVersion", JsonValue.String("1")),
            ("parserVersion", JsonValue.String("1")), ("coordinateProtocol", JsonValue.String("normalized_1000")),
            ("limits", Limits), ("allowedFallbackProfileRefs", JsonValue.Array(fallback ?? [])));

    public Task<JsonValue> CreateGui(JsonValue model, string name = "UI-TARS", JsonValue[]? fallback = null) =>
        Ok("ai.profiles.create", GuiParams(model, name, fallback));

    public static JsonValue Ref(JsonValue gui) => JsonValue.Obj(("guiProfileId", gui["guiProfileId"]!), ("revision", gui["revision"]!));

    /// <summary>All bytes of every file in the directory, read while SQLite may hold them open.</summary>
    public IEnumerable<(string Name, byte[] Bytes)> Files()
    {
        foreach (var f in Directory.GetFiles(Dir))
        {
            using var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var ms = new MemoryStream();
            fs.CopyTo(ms);
            yield return (Path.GetFileName(f), ms.ToArray());
        }
    }
}

public static class J
{
    public static JsonValue S(string s) => JsonValue.String(s);
    public static JsonValue I(long v) => JsonValue.Int(v);
    public static JsonValue O(params (string, JsonValue)[] m) => JsonValue.Obj(m);
    public static long Rev(JsonValue v) => v["revision"]!.IntValue!.Value;
}

using System.Net.Sockets;
using System.Text;
using AgentDesktop.Contracts;
using Xunit;

namespace AgentDesktop.Contracts.Tests;

// Case IDs refer to docs/ai-gui/tests/cases.csv. Ported one by one from
// Tests/AgentDesktopContractsTests/ContractsTests.swift; contract layer only.

internal static class Support
{
    public static readonly ContractBundle Contract = ContractBundle.Shared;

    public static readonly string RepoRoot = FindRoot();

    private static string FindRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "contracts", "ai-gui", "v1", "rpc.schema.json")))
            dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repository root not found");
    }

    public static string Uuid() => Guid.NewGuid().ToString().ToLowerInvariant();

    public static JsonValue Request(string command, JsonValue? @params = null, string? id = null, JsonValue? context = null)
    {
        var m = new List<(string, JsonValue)>
        {
            ("schemaVersion", JsonValue.String("agentdesktop.ai/1")),
            ("requestId", JsonValue.String(id ?? Uuid())),
            ("command", JsonValue.String(command)),
            ("params", @params ?? JsonValue.Obj()),
        };
        if (context is not null) m.Add(("context", context));
        return JsonValue.Obj([.. m]);
    }

    public static JsonValue Idem(string? key = null) =>
        JsonValue.Obj(("idempotencyKey", JsonValue.String(key ?? "key-" + Guid.NewGuid().ToString("N")[..8])));

    public static readonly JsonValue GoodConnection = JsonValue.Obj(
        ("connectionId", JsonValue.String("conn-1")),
        ("revision", JsonValue.Int(1)),
        ("name", JsonValue.String("Ark")),
        ("protocol", JsonValue.String("openai_chat")),
        ("baseUrl", JsonValue.String("https://ark.cn-beijing.volces.com/api/v3")),
        ("credentialRef", JsonValue.String("cred-1")),
        ("state", JsonValue.String("enabled")),
        ("timeoutMs", JsonValue.Int(30000)),
        ("createdAt", JsonValue.String("2026-10-08T03:00:00Z")),
        ("updatedAt", JsonValue.String("2026-10-08T03:00:00Z")));

    public static JsonValue DecodeLine(byte[] response)
    {
        Assert.Equal(0x0A, response[^1]);
        var body = response[..^1];
        Assert.DoesNotContain((byte)0x0A, body);
        return StrictJson.Parse(body);
    }

    public static string? ErrorCode(byte[] response) => DecodeLine(response)["error"]?["code"]?.StringValue;
}

public class ContractBundleTests
{
    [Fact]
    public void CatalogHasThe32OperationsWithSchemas()
    {
        var c = Support.Contract;
        Assert.Equal(32, c.Operations.Count);
        Assert.Equal(32, c.Operations.Select(o => o.Command).Distinct().Count());
        foreach (var op in c.Operations)
        {
            foreach (var suffix in new[] { "params", "result", "request" })
                c.Registry.Schema(ContractBundle.RpcSchemaId, $"/$defs/{op.DefPrefix}_{suffix}");
            var req = c.Registry.Schema(ContractBundle.RpcSchemaId, $"/$defs/{op.DefPrefix}_request");
            var required = req["properties"]?["context"]?["required"]?.ArrayValue ?? [];
            if (op.RequiresIdempotencyKey) Assert.Contains(JsonValue.String("idempotencyKey"), required);
        }
    }

    [Fact]
    public void ErrorCodesMatchTheSchemaEnum()
    {
        var schema = Support.Contract.Registry.Schema(ContractBundle.DomainSchemaId, "/$defs/ErrorCode");
        var fromSchema = schema["enum"]!.ArrayValue!.Select(v => v.StringValue!).ToHashSet();
        Assert.Equal(fromSchema, Enum.GetValues<ErrorCode>().Select(c => c.Wire()).ToHashSet());
        Assert.Equal("IPC_FRAME_TOO_LARGE", ErrorCode.IpcFrameTooLarge.Wire());
        Assert.Equal(ErrorCode.ActionOutcomeUnknown, ErrorCodes.FromWire("ACTION_OUTCOME_UNKNOWN"));
    }

    [Fact]
    public void EmbeddedFilesAreTheContractDirectory()
    {
        var asm = typeof(ContractBundle).Assembly;
        foreach (var name in new[] { "domain.schema.json", "rpc.schema.json", "operations.json" })
        {
            using var s = asm.GetManifestResourceStream(name)!;
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            Assert.Equal(File.ReadAllBytes(Path.Combine(Support.RepoRoot, "contracts", "ai-gui", "v1", name)), ms.ToArray());
        }
    }
}

public class StrictJsonTests
{
    [Theory]
    [InlineData("{\"a\":1,\"a\":2}")]
    [InlineData("{\"p\":{\"x\":1,\"x\":1}}")]
    [InlineData("[{\"k\":true,\"k\":false}]")]
    public void RejectsDuplicateKeysAtAnyDepth(string text) =>
        Assert.Equal(StrictJsonErrorKind.DuplicateKey, Assert.Throws<StrictJsonException>(() => StrictJson.Parse(text)).Kind);

    [Theory]
    [InlineData("")]
    [InlineData("{")]
    [InlineData("{\"a\":}")]
    [InlineData("[1,]")]
    [InlineData("{\"a\":1}x")]
    [InlineData("01")]
    [InlineData("1.")]
    [InlineData("NaN")]
    [InlineData("\"\\ud800\"")]
    [InlineData("\"tab\there\"")]
    [InlineData("1e999")]
    [InlineData("{\"a\":1} {\"b\":2}")]
    public void RejectsMalformedInput(string text) => Assert.Throws<StrictJsonException>(() => StrictJson.Parse(text));

    [Fact]
    public void RejectsInvalidUtf8() =>
        Assert.Equal(StrictJsonErrorKind.InvalidUtf8,
            Assert.Throws<StrictJsonException>(() => StrictJson.Parse(new byte[] { 0x22, 0xC3, 0x28, 0x22 })).Kind);

    [Fact]
    public void LimitsNesting()
    {
        Assert.Throws<StrictJsonException>(() => StrictJson.Parse(new string('[', 70) + new string(']', 70)));
        StrictJson.Parse(new string('[', 60) + new string(']', 60));
    }

    [Fact]
    public void RoundTripsAndKeepsOrderAndEscapes()
    {
        const string text = "{\"z\":1,\"a\":[true,null,-0.5,\"😀\\n\\\"\\u2028\"],\"m\":{\"k\":9007199254740991}}";
        var v = StrictJson.Parse(text);
        Assert.Equal(v, StrictJson.Parse(v.Encoded()));
        Assert.StartsWith("{\"z\":1,\"a\"", v.Encoded(), StringComparison.Ordinal);
        Assert.DoesNotContain("\n", v.Encoded(), StringComparison.Ordinal);
        Assert.Contains("\\u2028", v.Encoded(), StringComparison.Ordinal);
        Assert.Equal(9_007_199_254_740_991, v["m"]?["k"]?.IntValue);
    }

    [Fact]
    public void EncodingMatchesSwiftByteForByte()
    {
        // Swift: lowercase \u escapes for other controls, raw non-BMP scalars.
        var v = JsonValue.Obj(("s", JsonValue.String("a\u0001b\u2029c😀\b\f")));
        Assert.Equal("{\"s\":\"a\\u0001b\\u2029c😀\\b\\f\"}", v.Encoded());
    }
}

public class SchemaTests
{
    [Fact]
    public void ValidConnectionPasses() => Assert.Empty(Support.Contract.ValidateDomain(Support.GoodConnection, "AiConnection"));

    [Fact]
    public void UnknownMembersAreRefused()
    {
        var v = Support.Contract.ValidateDomain(Support.GoodConnection.Setting("apiKey", JsonValue.String("sk-canary")), "AiConnection");
        Assert.Contains(v, x => x.Keyword == "additionalProperties" && x.Path == "/apiKey");
    }

    // SEC-005 (schema part)
    [Theory]
    [InlineData("https://api.example.com/v1", true)]
    [InlineData("http://127.0.0.1:8080/v1", true)]
    [InlineData("http://localhost:11434", true)]
    [InlineData("http://[::1]:9000/api", true)]
    [InlineData("http://api.example.com/v1", false)]
    [InlineData("https://user:pw@api.example.com/v1", false)]
    [InlineData("https://api.example.com/v1?key=1", false)]
    [InlineData("https://api.example.com/v1#frag", false)]
    [InlineData("file:///etc/passwd", false)]
    [InlineData("https://", false)]
    public void EndpointRule(string url, bool ok)
    {
        var v = Support.Contract.ValidateDomain(Support.GoodConnection.Setting("baseUrl", JsonValue.String(url)), "AiConnection");
        Assert.Equal(ok, v.Count == 0);
    }

    // CFG-007 (schema part)
    [Fact]
    public void GuiLimitCeilings()
    {
        (string, long)[] ceiling =
        [
            ("maxSteps", 20), ("maxWallTimeMs", 120000), ("maxModelAttemptsPerStep", 2),
            ("maxTotalModelAttempts", 30), ("maxOutputTokens", 1024), ("maxWaitMs", 5000),
            ("maxScreenshots", 5), ("maxImageEncodedBytes", 8_388_608),
        ];
        var defaults = JsonValue.Obj([.. ceiling.Select(c => (c.Item1, JsonValue.Int(c.Item2))), ("requireReportedUsage", JsonValue.Bool(false))]);
        Assert.Empty(Support.Contract.ValidateDomain(defaults, "GuiLimits"));
        foreach (var (key, max) in ceiling)
            foreach (var bad in new[] { JsonValue.Int(max + 1), JsonValue.Int(-1), JsonValue.Double(1.5), JsonValue.String("1") })
                Assert.NotEmpty(Support.Contract.ValidateDomain(defaults.Setting(key, bad), "GuiLimits"));
        Assert.NotEmpty(Support.Contract.ValidateDomain(defaults.Setting("maxSteps", JsonValue.Int(0)), "GuiLimits"));
    }

    [Fact]
    public void DependentRequiredOnRunStart()
    {
        var b = JsonValue.Obj(
            ("desktopId", JsonValue.String("desk-a")),
            ("goal", JsonValue.String("在姓名中输入 Ada，然后点击应用")),
            ("verification", JsonValue.Obj(("kind", JsonValue.String("element_text_equals")), ("role", JsonValue.String("static_text")),
                                           ("text", JsonValue.String("已保存：Ada / MAC-001-A / 提交次数 1")))),
            ("allowedActions", JsonValue.Array([JsonValue.String("click"), JsonValue.String("type")])));
        var c = Support.Contract;
        Assert.Empty(c.ValidateRpc(b, "gui_runs_start_params"));
        Assert.Contains(c.ValidateRpc(b.Setting("guiProfileId", JsonValue.String("gp-1")), "gui_runs_start_params"), x => x.Keyword == "dependentRequired");
        Assert.Contains(c.ValidateRpc(b.Setting("allowedActions", JsonValue.Array([JsonValue.String("click"), JsonValue.String("click")])), "gui_runs_start_params"),
                        x => x.Keyword == "uniqueItems");
        Assert.NotEmpty(c.ValidateRpc(b.Setting("allowedActions", JsonValue.Array([JsonValue.String("drag")])), "gui_runs_start_params"));
    }

    [Fact]
    public void FormatChecks()
    {
        Assert.True(Formats.Check("uuid", "11111111-1111-4111-8111-111111111111"));
        Assert.False(Formats.Check("uuid", "11111111-1111-4111-8111-11111111111"));
        Assert.True(Formats.Check("date-time", "2026-10-08T03:00:00.123+08:00"));
        Assert.False(Formats.Check("date-time", "2026-02-30T03:00:00Z"));
        Assert.False(Formats.Check("date-time", "2026-10-08 03:00:00Z"));
    }

    [Fact]
    public void UnsupportedKeywordIsRefusedAtLoad()
    {
        var doc = JsonValue.Obj(("$id", JsonValue.String("https://x.invalid/s.json")),
            ("$defs", JsonValue.Obj(("A", JsonValue.Obj(("type", JsonValue.String("string")), ("contentEncoding", JsonValue.String("base64")))))));
        Assert.Throws<SchemaException>(() => new SchemaRegistry().Add(doc));
    }
}

public class EnvelopeTests
{
    private sealed class Counter { public int Value; }

    private static RpcRouter Router(Counter calls, bool legacy = true)
    {
        var handlers = new Dictionary<string, RpcHandler>
        {
            ["ai.connections.list"] = (_, _) =>
            {
                Interlocked.Increment(ref calls.Value);
                return Task.FromResult(JsonValue.Obj(("items", JsonValue.Array([Support.GoodConnection])), ("nextCursor", JsonValue.Null)));
            },
            ["ai.modelProfiles.list"] = (_, _) =>
            {
                Interlocked.Increment(ref calls.Value);
                return Task.FromResult(JsonValue.Obj(("items", JsonValue.Array([Support.GoodConnection.Setting("apiKey", JsonValue.String("sk-canary"))])),
                                                     ("nextCursor", JsonValue.Null)));
            },
        };
        Func<JsonValue, Task<byte[]>>? legacyHandler = legacy ? _ => Task.FromResult(Encoding.UTF8.GetBytes("{\"ok\":true}\n")) : null;
        return new RpcRouter(handlers, legacyHandler);
    }

    // RPC-001
    [Fact]
    public async Task SuccessCorrelatesAndIsOneLine()
    {
        var calls = new Counter();
        var id = Support.Uuid();
        var v = Support.DecodeLine(await Router(calls).RespondToBody(
            Support.Request("ai.connections.list", JsonValue.Obj(("limit", JsonValue.Int(20))), id).EncodedBytes()));
        Assert.Equal("agentdesktop.ai/1", v["schemaVersion"]?.StringValue);
        Assert.Equal(id, v["requestId"]?.StringValue);
        Assert.True(v["ok"]?.BoolValue);
        Assert.Null(v["error"]);
        Assert.Empty(Support.Contract.ValidateRpc(v, "SuccessResponse"));
        Assert.Equal(1, calls.Value);
    }

    // RPC-002
    [Fact]
    public async Task VersionRouting()
    {
        var calls = new Counter();
        var r = Router(calls);
        Assert.Equal("{\"ok\":true}\n", Encoding.UTF8.GetString(await r.RespondToBody(Encoding.UTF8.GetBytes("{\"command\":\"screen.list\"}"))));
        var req = Support.Request("ai.connections.list").Setting("schemaVersion", JsonValue.String("agentdesktop.ai/2"));
        Assert.Equal("UNSUPPORTED_SCHEMA", Support.ErrorCode(await r.RespondToBody(req.EncodedBytes())));
        req = JsonValue.Obj(("schemaVersion", JsonValue.String("agentdesktop.ai/1")), ("requestId", JsonValue.String(Support.Uuid())),
                            ("op", JsonValue.String("ai.connections.list")), ("params", JsonValue.Obj()));
        Assert.Equal("VALIDATION_ERROR", Support.ErrorCode(await r.RespondToBody(req.EncodedBytes())));
        Assert.Equal(0, calls.Value);
        Assert.Equal("UNSUPPORTED_SCHEMA", Support.ErrorCode(await Router(calls, legacy: false)
            .RespondToBody(Encoding.UTF8.GetBytes("{\"command\":\"screen.list\"}"))));
    }

    // RPC-003
    [Fact]
    public async Task HostileInputsThenAValidOne()
    {
        var calls = new Counter();
        var r = Router(calls);
        var id = Support.Uuid();
        var start = Support.Request("gui.runs.start", JsonValue.Obj(
            ("desktopId", JsonValue.String("desk-a")), ("goal", JsonValue.String("x")),
            ("allowedActions", JsonValue.Array([JsonValue.String("click")]))), context: Support.Idem());
        (string Name, byte[] Body, string Code)[] cases =
        [
            ("malformed", Encoding.UTF8.GetBytes("{\"schemaVersion\":"), "VALIDATION_ERROR"),
            ("duplicate command", Encoding.UTF8.GetBytes($"{{\"schemaVersion\":\"agentdesktop.ai/1\",\"requestId\":\"{id}\",\"command\":\"ai.connections.list\",\"command\":\"gui.runs.cancel\",\"params\":{{}}}}"), "VALIDATION_ERROR"),
            ("bad uuid", Support.Request("ai.connections.list", id: "not-a-uuid").EncodedBytes(), "VALIDATION_ERROR"),
            ("unknown command", Support.Request("gui.runs.resume").EncodedBytes(), "UNSUPPORTED_COMMAND"),
            ("extra control field", Support.Request("ai.connections.list").Setting("lease", JsonValue.String("forged")).EncodedBytes(), "VALIDATION_ERROR"),
            ("start without verification", start.EncodedBytes(), "VALIDATION_ERROR"),
            ("model script as verification", start.Setting("params", start["params"]!.Setting("verification",
                JsonValue.Obj(("kind", JsonValue.String("script")), ("code", JsonValue.String("return true"))))).EncodedBytes(), "VALIDATION_ERROR"),
            ("mutation without idempotency key", Support.Request("ai.connections.disable",
                JsonValue.Obj(("connectionId", JsonValue.String("c")), ("expectedRevision", JsonValue.Int(1)))).EncodedBytes(), "VALIDATION_ERROR"),
            ("array frame", Encoding.UTF8.GetBytes("[]"), "VALIDATION_ERROR"),
        ];
        foreach (var (name, body, code) in cases)
        {
            var reply = await r.RespondToBody(body);
            Assert.True(code == Support.ErrorCode(reply), name);
            Assert.True(Support.Contract.ValidateRpc(Support.DecodeLine(reply), "ErrorResponse").Count == 0, $"{name}: refusal breaks the contract");
        }
        Assert.Equal(0, calls.Value);
        Assert.True(Support.DecodeLine(await r.RespondToBody(Support.Request("ai.connections.list").EncodedBytes()))["ok"]?.BoolValue);
        Assert.Equal(1, calls.Value);
    }

    [Fact]
    public async Task CorrelatableErrorsEchoTheRequestId()
    {
        var calls = new Counter();
        var id = Support.Uuid();
        Assert.Equal(id, Support.DecodeLine(await Router(calls).RespondToBody(Support.Request("gui.runs.resume", id: id).EncodedBytes()))["requestId"]?.StringValue);
        Assert.True(Support.DecodeLine(await Router(calls).RespondToBody("{"u8.ToArray()))["requestId"]?.IsNull);
    }

    // RPC-004
    [Fact]
    public async Task FrameBoundary()
    {
        var calls = new Counter();
        var r = Router(calls);
        var b = Support.Request("ai.connections.list", JsonValue.Obj(("cursor", JsonValue.String("c")))).Encoded();
        byte[] Padded(int total) => Encoding.UTF8.GetBytes(b[..^1] + new string(' ', total - 1 - Encoding.UTF8.GetByteCount(b)) + "}");
        var exact = Padded(Envelope.MaxFrameBytes);
        Assert.Equal(Envelope.MaxFrameBytes, exact.Length + 1);
        var split = FrameReader.Split([.. exact, 0x0A]);
        Assert.Equal(FrameResultKind.Frame, split.Kind);
        Assert.True(Support.DecodeLine(await r.RespondToBody(split.Body!))["ok"]?.BoolValue);
        Assert.Equal(FrameResultKind.TooLarge, FrameReader.Split([.. Padded(Envelope.MaxFrameBytes + 1), 0x0A]).Kind);
        Assert.Equal("IPC_FRAME_TOO_LARGE", Support.ErrorCode(await r.RespondTo(FrameResult.TooLarge)));
        var inline = Support.Request("ai.connections.list", JsonValue.Obj(("screenshot", JsonValue.String(new string('A', 1000)))));
        Assert.Equal("VALIDATION_ERROR", Support.ErrorCode(await r.RespondToBody(inline.EncodedBytes())));
        Assert.Equal(1, calls.Value);
    }

    [Fact]
    public void FrameReaderOnAStreamStopsAtTheLimit()
    {
        var payload = Encoding.UTF8.GetBytes(Support.Request("ai.connections.list").Encoded() + "\n");
        var read = FrameReader.Read(new MemoryStream(payload));
        Assert.Equal(FrameResultKind.Frame, read.Kind);
        Assert.Equal(payload.Length - 1, read.Body!.Length);
        // A stream that never sends LF is cut at the limit, not buffered to the end.
        var endless = new CountingStream(new byte[Envelope.MaxFrameBytes * 4]);
        Assert.Equal(FrameResultKind.TooLarge, FrameReader.Read(endless).Kind);
        Assert.True(endless.BytesRead <= Envelope.MaxFrameBytes);
    }

    [Fact]
    public async Task FrameReaderOnAUnixSocket()
    {
        var path = Path.Combine(Path.GetTempPath(), $"adc-{Environment.ProcessId}-{Random.Shared.Next()}.sock");
        using var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        listener.Bind(new UnixDomainSocketEndPoint(path));
        listener.Listen(1);
        try
        {
            using var client = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            await client.ConnectAsync(new UnixDomainSocketEndPoint(path));
            using var server = await listener.AcceptAsync();
            var payload = Encoding.UTF8.GetBytes(Support.Request("ai.connections.list").Encoded() + "\n");
            await client.SendAsync(payload);
            client.Shutdown(SocketShutdown.Send);
            using var stream = new NetworkStream(server);
            var read = FrameReader.Read(stream);
            Assert.Equal(FrameResultKind.Frame, read.Kind);
            Assert.Equal(payload.Length - 1, read.Body!.Length);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public async Task MultipleRequestsInOneConnectionAreRefused()
    {
        var calls = new Counter();
        var two = Encoding.UTF8.GetBytes(Support.Request("ai.connections.list").Encoded() + "\n" + Support.Request("ai.connections.list").Encoded() + "\n");
        Assert.Equal("VALIDATION_ERROR", Support.ErrorCode(await Router(calls).RespondTo(FrameReader.Split(two))));
        Assert.Equal(0, calls.Value);
    }

    [Fact]
    public async Task ResultsAreCheckedAgainstTheContract()
    {
        var calls = new Counter();
        var outBytes = await Router(calls).RespondToBody(Support.Request("ai.modelProfiles.list").EncodedBytes());
        Assert.Equal("INTERNAL_ERROR", Support.ErrorCode(outBytes));
        Assert.DoesNotContain("sk-canary", Encoding.UTF8.GetString(outBytes), StringComparison.Ordinal);
    }

    [Fact]
    public async Task KnownCommandWithoutHandler() =>
        Assert.Equal("UNSUPPORTED_COMMAND", Support.ErrorCode(await Router(new Counter()).RespondToBody(Support.Request("runtime.capabilities").EncodedBytes())));

    [Fact]
    public async Task HandlerExceptionsBecomeContractErrorsWithoutDetail()
    {
        var router = new RpcRouter(new Dictionary<string, RpcHandler>
        {
            ["ai.connections.list"] = (_, _) => throw new InvalidOperationException("secret path /Users/x"),
            ["ai.connections.get"] = (_, _) => throw new ContractError(ErrorCode.NotFound, "no such connection"),
            ["runtime.capabilities"] = (_, _) => throw new OperationCanceledException(),
        });
        var internalError = await router.RespondToBody(Support.Request("ai.connections.list").EncodedBytes());
        Assert.Equal("INTERNAL_ERROR", Support.ErrorCode(internalError));
        Assert.DoesNotContain("/Users/x", Encoding.UTF8.GetString(internalError), StringComparison.Ordinal);
        Assert.Equal("NOT_FOUND", Support.ErrorCode(await router.RespondToBody(
            Support.Request("ai.connections.get", JsonValue.Obj(("connectionId", JsonValue.String("c1")))).EncodedBytes())));
        Assert.Equal("CANCELLED", Support.ErrorCode(await router.RespondToBody(Support.Request("runtime.capabilities").EncodedBytes())));
    }

    [Fact]
    public async Task ValidationDetailsCarryNoValues()
    {
        var req = Support.Request("ai.connections.create", JsonValue.Obj(
            ("name", JsonValue.String("x")), ("protocol", JsonValue.String("openai_chat")),
            ("baseUrl", JsonValue.String("http://evil.example.com")), ("timeoutMs", JsonValue.Int(1000)),
            ("credential", JsonValue.Obj(("apiKey", JsonValue.String("sk-canary-123")))), ("extra", JsonValue.String("sk-canary-456"))),
            context: Support.Idem());
        var outBytes = await Router(new Counter()).RespondToBody(req.EncodedBytes());
        var text = Encoding.UTF8.GetString(outBytes);
        Assert.Equal("VALIDATION_ERROR", Support.ErrorCode(outBytes));
        Assert.DoesNotContain("sk-canary", text, StringComparison.Ordinal);
        Assert.DoesNotContain("evil.example.com", text, StringComparison.Ordinal);
        Assert.Contains("/params/baseUrl", text, StringComparison.Ordinal);
    }

    private sealed class CountingStream(byte[] data) : MemoryStream(data)
    {
        public long BytesRead;
        public override int Read(byte[] buffer, int offset, int count)
        {
            var n = base.Read(buffer, offset, count);
            BytesRead += n;
            return n;
        }
    }
}

// The request/response examples printed in the implementation plan.
public class SpecExampleTests
{
    private static readonly JsonValue Examples = StrictJson.Parse(File.ReadAllBytes(
        Path.Combine(Support.RepoRoot, "Tests", "AgentDesktopContractsTests", "Fixtures", "spec-examples.json")));

    [Fact]
    public void EveryRequestExampleDecodes()
    {
        var pairs = Examples["pairs"]!.ArrayValue!;
        var requests = pairs.Select(p => p["request"]!).Concat(Examples["extraRequests"]?.ArrayValue ?? []).ToList();
        Assert.Equal(32, pairs.Select(p => p["command"]!.StringValue).Distinct().Count());
        Assert.Equal(35, requests.Count);
        foreach (var r in requests)
        {
            var d = Envelope.Decode(r.EncodedBytes());
            Assert.True(d.Kind == DecodedKind.Request, $"{r["command"]?.StringValue}: {d.Error} {d.Error?.Details}");
        }
    }

    [Fact]
    public void EverySuccessExampleMatchesItsResultSchema()
    {
        var pairs = Examples["pairs"]!.ArrayValue!;
        Assert.Equal(32, pairs.Count);
        foreach (var p in pairs)
        {
            var command = p["command"]!.StringValue!;
            var s = p["success"]!;
            Assert.Equal(p["request"]!["requestId"], s["requestId"]);
            Assert.Empty(Support.Contract.ValidateRpc(s, "SuccessResponse"));
            var op = Support.Contract.Operation(command)!;
            var v = Support.Contract.ValidateRpc(s["result"]!, $"{op.DefPrefix}_result");
            Assert.True(v.Count == 0, $"{command}: {string.Join("; ", v)}");
        }
    }

    [Fact]
    public void ErrorExampleMatchesTheErrorEnvelope()
    {
        var errors = Examples["errors"]!.ArrayValue!;
        Assert.Single(errors);
        foreach (var e in errors) Assert.Empty(Support.Contract.ValidateRpc(e, "ErrorResponse"));
    }
}

// Frames the Swift layer must judge the same way (Fixtures/cross-platform-envelope.json).
public class CrossPlatformEnvelopeTests
{
    private static readonly JsonValue Doc = StrictJson.Parse(File.ReadAllBytes(
        Path.Combine(AppContext.BaseDirectory, "Fixtures", "cross-platform-envelope.json")));

    internal static byte[] Bytes(JsonValue c, string field)
    {
        if (c["frameBase64"]?.StringValue is { } b64) return Convert.FromBase64String(b64);
        var text = c[field]!.StringValue!;
        if (c["padToBodyBytes"]?.IntValue is { } target)
        {
            var current = Encoding.UTF8.GetByteCount(text);
            text = text[..^1] + new string(' ', (int)target - current) + "}";
        }
        var bytes = Encoding.UTF8.GetBytes(text);
        return c["appendLF"]?.BoolValue == true ? [.. bytes, 0x0A] : bytes;
    }

    public static TheoryData<string> EnvelopeCases =>
        [.. Doc["envelope"]!.ArrayValue!.Select(c => c["name"]!.StringValue!)];

    public static TheoryData<string> FrameCases =>
        [.. Doc["frames"]!.ArrayValue!.Select(c => c["name"]!.StringValue!)];

    [Theory]
    [MemberData(nameof(EnvelopeCases))]
    public void Envelope(string name)
    {
        var c = Doc["envelope"]!.ArrayValue!.Single(x => x["name"]!.StringValue == name);
        var expect = c["expect"]!;
        var d = Contracts.Envelope.Decode(Bytes(c, "frame"));
        Assert.Equal(expect["kind"]!.StringValue, d.Kind.ToString().ToLowerInvariant());
        if (d.Kind == DecodedKind.Request)
        {
            Assert.Equal(expect["command"]?.StringValue, d.Request!.Command);
            if (expect["idempotencyKey"] is { } key) Assert.Equal(key.StringValue, d.Request.IdempotencyKey);
            return;
        }
        if (d.Kind != DecodedKind.Rejected) return;
        var response = d.Response!;
        Assert.Empty(Support.Contract.ValidateRpc(response, "ErrorResponse"));
        Assert.Equal(expect["code"]!.StringValue, d.Error!.Code.Wire());
        if (expect["requestId"] is { } id) Assert.Equal(id, response["requestId"]);
        if (expect["reasonCode"]?.StringValue is { } reason) Assert.Equal(reason, d.Error.Details?["reasonCode"]?.StringValue);
        if (expect["fieldErrorPaths"]?.ArrayValue is { } paths)
        {
            var got = d.Error.Details!["fieldErrors"]!.ArrayValue!.Select(v => v["path"]!.StringValue).ToHashSet();
            foreach (var p in paths) Assert.Contains(p.StringValue, got);
        }
        foreach (var bad in expect["mustNotContain"]?.ArrayValue ?? [])
            Assert.DoesNotContain(bad.StringValue!, response.Encoded(), StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(FrameCases))]
    public void Frame(string name)
    {
        var c = Doc["frames"]!.ArrayValue!.Single(x => x["name"]!.StringValue == name);
        var expect = c["expect"]!.StringValue!;
        var bytes = Bytes(c, "data");
        Assert.Equal(expect, Camel(FrameReader.Split(bytes).Kind));
        Assert.Equal(expect, Camel(FrameReader.Read(new MemoryStream(bytes)).Kind));
    }

    private static string Camel(FrameResultKind k) => char.ToLowerInvariant(k.ToString()[0]) + k.ToString()[1..];
}

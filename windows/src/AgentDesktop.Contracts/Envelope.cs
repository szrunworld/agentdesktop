namespace AgentDesktop.Contracts;

/// <summary>A versioned request that passed framing, strict parsing and its rpc.schema.json request definition.</summary>
public sealed record RpcRequest(string RequestId, string Command, OperationSpec Operation, JsonValue Params,
                                string? DeadlineAt, string? IdempotencyKey, JsonValue Raw);

public enum DecodedKind { Request, Legacy, Rejected }

/// <summary>What one frame turned into.</summary>
public sealed record DecodedFrame(DecodedKind Kind, RpcRequest? Request = null, JsonValue? Legacy = null,
                                  JsonValue? Response = null, ContractError? Error = null);

public static class Envelope
{
    /// <summary>Frame limit including the terminating LF (§05.1).</summary>
    public const int MaxFrameBytes = 1_048_576;

    public static JsonValue Success(string requestId, JsonValue result) => JsonValue.Obj(
        ("schemaVersion", JsonValue.String(ContractBundle.SchemaVersion)),
        ("requestId", JsonValue.String(requestId)),
        ("ok", JsonValue.Bool(true)),
        ("result", result));

    /// <summary>requestId may be null only for VALIDATION_ERROR, UNSUPPORTED_SCHEMA and IPC_FRAME_TOO_LARGE.</summary>
    public static JsonValue Failure(string? requestId, ContractError error)
    {
        if (requestId is null && error.Code is not (ErrorCode.ValidationError or ErrorCode.UnsupportedSchema or ErrorCode.IpcFrameTooLarge))
            throw new InvalidOperationException("only an uncorrelatable framing error may answer with requestId null");
        return JsonValue.Obj(
            ("schemaVersion", JsonValue.String(ContractBundle.SchemaVersion)),
            ("requestId", requestId is null ? JsonValue.Null : JsonValue.String(requestId)),
            ("ok", JsonValue.Bool(false)),
            ("error", error.Json));
    }

    /// <summary>One response line: compact JSON plus LF.</summary>
    public static byte[] Line(JsonValue response)
    {
        var body = response.EncodedBytes();
        var line = new byte[body.Length + 1];
        body.CopyTo(line, 0);
        line[^1] = 0x0A;
        return line;
    }

    private static DecodedFrame Reject(string? id, ContractError e) =>
        new(DecodedKind.Rejected, Response: Failure(id, e), Error: e);

    /// <summary>Decode one frame body (the bytes before its LF).</summary>
    public static DecodedFrame Decode(byte[] body, ContractBundle? contract = null)
    {
        contract ??= ContractBundle.Shared;
        if (body.Length >= MaxFrameBytes)
            return Reject(null, new ContractError(ErrorCode.IpcFrameTooLarge, $"request frame exceeds {MaxFrameBytes} bytes"));
        JsonValue value;
        try
        {
            value = StrictJson.Parse(body);
        }
        catch (StrictJsonException e)
        {
            return Reject(null, new ContractError(ErrorCode.ValidationError, "request is not valid JSON",
                details: JsonValue.Obj(("reasonCode", JsonValue.String(StrictJsonException.WireName(e.Kind))))));
        }
        if (value.Kind != JsonKind.Object)
            return Reject(null, new ContractError(ErrorCode.ValidationError, "request must be one JSON object"));
        if (value["schemaVersion"] is not { } version) return new DecodedFrame(DecodedKind.Legacy, Legacy: value);

        // Correlate as early as possible; a malformed id cannot be echoed.
        var rawId = value["requestId"]?.StringValue;
        var requestId = rawId is not null && Formats.Check("uuid", rawId) ? rawId : null;

        if (version.StringValue != ContractBundle.SchemaVersion)
            return Reject(requestId, new ContractError(ErrorCode.UnsupportedSchema,
                $"unsupported schemaVersion; this build speaks {ContractBundle.SchemaVersion}"));
        if (requestId is null)
            return Reject(null, new ContractError(ErrorCode.ValidationError, "requestId must be a UUID string"));
        if (value["command"]?.StringValue is not { } command)
            return Reject(requestId, new ContractError(ErrorCode.ValidationError, "command is required"));
        if (contract.Operation(command) is not { } op)
            return Reject(requestId, new ContractError(ErrorCode.UnsupportedCommand, "unknown command"));
        IReadOnlyList<SchemaViolation> violations;
        try
        {
            violations = contract.ValidateRpc(value, $"{op.DefPrefix}_request");
        }
        catch (SchemaException)
        {
            return Reject(requestId, new ContractError(ErrorCode.InternalError, "contract schema unavailable"));
        }
        if (violations.Count > 0)
            return Reject(requestId, new ContractError(ErrorCode.ValidationError, "request does not match the contract",
                details: ViolationDetails(violations)));
        var context = value["context"];
        return new DecodedFrame(DecodedKind.Request, Request: new RpcRequest(
            requestId, command, op, value["params"] ?? JsonValue.Obj(),
            context?["deadlineAt"]?.StringValue, context?["idempotencyKey"]?.StringValue, value));
    }

    /// <summary>
    /// Violations as RpcError.details.fieldErrors: pointer and keyword only,
    /// never the offending value (it may be a secret). At most 20, each
    /// path within the contract's 256 characters.
    /// </summary>
    public static JsonValue ViolationDetails(IEnumerable<SchemaViolation> v) =>
        JsonValue.Obj(("fieldErrors", JsonValue.Array(v.Take(20).Select(x => JsonValue.Obj(
            ("path", JsonValue.String(Truncate(x.Path.Length == 0 ? "/" : x.Path, 256))),
            ("code", JsonValue.String(Truncate(x.Keyword, 96))))))));

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];
}

public enum FrameResultKind { Frame, TooLarge, Truncated, TrailingData, IoError }

public sealed record FrameResult(FrameResultKind Kind, byte[]? Body = null)
{
    public static FrameResult TooLarge { get; } = new(FrameResultKind.TooLarge);
}

/// <summary>Reads one LF-terminated frame, refusing to buffer more than MaxFrameBytes (LF included).</summary>
public static class FrameReader
{
    public static FrameResult Read(Stream stream, int limit = Envelope.MaxFrameBytes)
    {
        var body = new MemoryStream();
        var chunk = new byte[64 * 1024];
        while (true)
        {
            var want = (int)Math.Min(chunk.Length, limit - body.Length);
            if (want <= 0) return FrameResult.TooLarge;
            int n;
            try { n = stream.Read(chunk, 0, want); }
            catch (IOException) { return new FrameResult(FrameResultKind.IoError); }
            if (n == 0) return new FrameResult(FrameResultKind.Truncated, body.ToArray());
            var lf = System.Array.IndexOf(chunk, (byte)0x0A, 0, n);
            if (lf >= 0)
            {
                body.Write(chunk, 0, lf);
                return lf + 1 < n
                    ? new FrameResult(FrameResultKind.TrailingData, body.ToArray())
                    : new FrameResult(FrameResultKind.Frame, body.ToArray());
            }
            body.Write(chunk, 0, n);
        }
    }

    public static FrameResult Split(byte[] data, int limit = Envelope.MaxFrameBytes)
    {
        var lf = System.Array.IndexOf(data, (byte)0x0A);
        if (lf < 0) return data.Length >= limit ? FrameResult.TooLarge : new FrameResult(FrameResultKind.Truncated, data);
        if (lf + 1 > limit) return FrameResult.TooLarge;
        var body = data[..lf];
        return lf + 1 < data.Length ? new FrameResult(FrameResultKind.TrailingData, body) : new FrameResult(FrameResultKind.Frame, body);
    }
}

public delegate Task<JsonValue> RpcHandler(RpcRequest request, CancellationToken cancellationToken);

/// <summary>
/// Routes v1 requests to handlers and pre-v1 requests to the legacy decoder.
/// Both must end in the same Runtime; the router owns no executor.
/// </summary>
public sealed class RpcRouter(IReadOnlyDictionary<string, RpcHandler> handlers,
                              Func<JsonValue, Task<byte[]>>? legacy = null,
                              bool checkResults = true,
                              Action<string, string>? onInternalFault = null,
                              ContractBundle? contract = null)
{
    public ContractBundle Contract { get; } = contract ?? ContractBundle.Shared;

    public async Task<byte[]> RespondTo(FrameResult read, CancellationToken ct = default) => read.Kind switch
    {
        FrameResultKind.Frame => await RespondToBody(read.Body!, ct).ConfigureAwait(false),
        FrameResultKind.TooLarge => Envelope.Line(Envelope.Failure(null,
            new ContractError(ErrorCode.IpcFrameTooLarge, $"request frame exceeds {Envelope.MaxFrameBytes} bytes"))),
        _ => Envelope.Line(Envelope.Failure(null,
            new ContractError(ErrorCode.ValidationError, "a connection carries exactly one LF-terminated request"))),
    };

    public async Task<byte[]> RespondToBody(byte[] body, CancellationToken ct = default)
    {
        var decoded = Envelope.Decode(body, Contract);
        switch (decoded.Kind)
        {
            case DecodedKind.Rejected:
                return Envelope.Line(decoded.Response!);
            case DecodedKind.Legacy:
                if (legacy is null)
                    return Envelope.Line(Envelope.Failure(null, new ContractError(ErrorCode.UnsupportedSchema, "schemaVersion is required")));
                return await legacy(decoded.Legacy!).ConfigureAwait(false);
            default:
                return Envelope.Line(await Answer(decoded.Request!, ct).ConfigureAwait(false));
        }
    }

    public async Task<JsonValue> Answer(RpcRequest req, CancellationToken ct = default)
    {
        if (!handlers.TryGetValue(req.Command, out var handler))
            return Envelope.Failure(req.RequestId, new ContractError(ErrorCode.UnsupportedCommand, "command is not implemented in this build"));
        try
        {
            var result = await handler(req, ct).ConfigureAwait(false);
            if (checkResults)
            {
                var v = Contract.ValidateRpc(result, $"{req.Operation.DefPrefix}_result");
                if (v.Count > 0)
                {
                    onInternalFault?.Invoke(req.Command, "result breaks the contract: " + string.Join("; ", v.Take(5)));
                    return Envelope.Failure(req.RequestId, new ContractError(ErrorCode.InternalError, "internal error"));
                }
            }
            return Envelope.Success(req.RequestId, result);
        }
        catch (ContractError e)
        {
            return Envelope.Failure(req.RequestId, e);
        }
        catch (OperationCanceledException)
        {
            return Envelope.Failure(req.RequestId, new ContractError(ErrorCode.Cancelled, "cancelled"));
        }
#pragma warning disable CA1031 // Any other failure becomes INTERNAL_ERROR without detail.
        catch (Exception e)
#pragma warning restore CA1031
        {
            onInternalFault?.Invoke(req.Command, e.GetType().Name);
            return Envelope.Failure(req.RequestId, new ContractError(ErrorCode.InternalError, "internal error"));
        }
    }
}

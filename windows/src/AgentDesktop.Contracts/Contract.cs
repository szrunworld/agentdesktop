using System.Reflection;

namespace AgentDesktop.Contracts;

/// <summary>Error codes of contract v1 (domain.schema.json#/$defs/ErrorCode).</summary>
public enum ErrorCode
{
    ValidationError, UnsupportedSchema, UnsupportedCommand, IpcFrameTooLarge,
    Unauthorized, Forbidden, NotFound, ConfigConflict, IdempotencyConflict,
    ResourceInUse, ResourceDisabled, UnsupportedProtocol, CapabilityMismatch,
    CredentialRequired, CredentialRevoked, AuthFailed, RateLimited,
    UpstreamUnavailable, UpstreamProtocolError, ModelNotFound, DeadlineExceeded,
    Cancelled, OperationNotCancellable, DesktopBusy, StaleObservation,
    StaleGeneration, InvalidAction, CoordinateOutOfBounds, ActionOutcomeUnknown,
    VerificationFailed, LimitExceeded, UsageUnavailable, EventsCursorExpired,
    AuditUnavailable, InternalError,
}

public static class ErrorCodes
{
    private static readonly Dictionary<ErrorCode, string> ToWireMap = Enum.GetValues<ErrorCode>()
        .ToDictionary(c => c, c => string.Concat(c.ToString().Select((ch, i) =>
            i > 0 && char.IsUpper(ch) ? "_" + ch : char.ToUpperInvariant(ch).ToString())));
    private static readonly Dictionary<string, ErrorCode> FromWireMap =
        ToWireMap.ToDictionary(p => p.Value, p => p.Key, StringComparer.Ordinal);

    /// <summary>The wire value, e.g. ValidationError → "VALIDATION_ERROR".</summary>
    public static string Wire(this ErrorCode code) => ToWireMap[code];

    public static ErrorCode? FromWire(string value) => FromWireMap.TryGetValue(value, out var c) ? c : null;

    /// <summary>Whether a failure of this kind may have a recovery path; not permission to replay a GUI run (§05.5).</summary>
    public static bool DefaultRetryable(this ErrorCode code) => code is ErrorCode.RateLimited
        or ErrorCode.UpstreamUnavailable or ErrorCode.DesktopBusy or ErrorCode.StaleObservation or ErrorCode.AuditUnavailable;
}

/// <summary>
/// A failure that leaves the service as a contract error. Message and
/// Details must never carry secrets or upstream bodies.
/// </summary>
public sealed class ContractError(ErrorCode code, string message, bool? retryable = null, JsonValue? details = null)
    : Exception(message)
{
    public ErrorCode Code { get; } = code;
    public bool Retryable { get; } = retryable ?? code.DefaultRetryable();
    public JsonValue? Details { get; } = details;

    public override string ToString() => $"{Code.Wire()}: {Message}";

    public JsonValue Json
    {
        get
        {
            var m = new List<(string, JsonValue)>
            {
                ("code", JsonValue.String(Code.Wire())),
                ("message", JsonValue.String(Message)),
                ("retryable", JsonValue.Bool(Retryable)),
            };
            if (Details is not null) m.Add(("details", Details));
            return JsonValue.Obj([.. m]);
        }
    }
}

/// <summary>One entry of contracts/ai-gui/v1/operations.json.</summary>
public sealed record OperationSpec(string Command, bool Mutation, bool Asynchronous, bool RequiresIdempotencyKey,
                                   string ParamsRef, string ResultRef)
{
    /// <summary>"gui.runs.start" → "gui_runs_start", the rpc.schema.json $defs prefix.</summary>
    public string DefPrefix => Command.Replace('.', '_');
}

/// <summary>Both schemas and the operation catalog, loaded once.</summary>
public sealed class ContractBundle
{
    public const string SchemaVersion = "agentdesktop.ai/1";
    public const string DomainSchemaId = "https://schemas.agentdesktop.invalid/ai-gui/v1/domain.schema.json";
    public const string RpcSchemaId = "https://schemas.agentdesktop.invalid/ai-gui/v1/rpc.schema.json";

    public SchemaRegistry Registry { get; }
    public IReadOnlyList<OperationSpec> Operations { get; }
    private readonly Dictionary<string, OperationSpec> _byCommand;

    private static readonly Lazy<ContractBundle> SharedLazy = new(() =>
    {
        var asm = typeof(ContractBundle).Assembly;
        return new ContractBundle(Read(asm, "domain.schema.json"), Read(asm, "rpc.schema.json"), Read(asm, "operations.json"));
    });

    /// <summary>The contract shipped in this build.</summary>
    public static ContractBundle Shared => SharedLazy.Value;

    private static byte[] Read(Assembly asm, string name)
    {
        using var stream = asm.GetManifestResourceStream(name) ?? throw new SchemaException($"missing contract file {name}");
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return ms.ToArray();
    }

    public ContractBundle(byte[] domain, byte[] rpc, byte[] operations)
    {
        Registry = new SchemaRegistry();
        Registry.Add(domain);
        Registry.Add(rpc);
        var catalog = StrictJson.Parse(operations);
        if (catalog["schemaVersion"]?.StringValue != SchemaVersion || catalog["operations"]?.ArrayValue is not { } list)
            throw new SchemaException($"operations.json is not for {SchemaVersion}");
        var specs = new List<OperationSpec>();
        foreach (var item in list)
        {
            if (item["command"]?.StringValue is not { } command || item["mutation"]?.BoolValue is not { } mutation
                || item["asynchronous"]?.BoolValue is not { } asynchronous || item["requiresIdempotencyKey"]?.BoolValue is not { } idem
                || item["paramsRef"]?.StringValue is not { } paramsRef || item["resultRef"]?.StringValue is not { } resultRef)
                throw new SchemaException($"operations.json entry is incomplete: {item.Encoded()}");
            specs.Add(new OperationSpec(command, mutation, asynchronous, idem, paramsRef, resultRef));
        }
        Operations = specs;
        _byCommand = specs.ToDictionary(s => s.Command, StringComparer.Ordinal);
    }

    public OperationSpec? Operation(string command) => _byCommand.GetValueOrDefault(command);

    public IReadOnlyList<SchemaViolation> ValidateDomain(JsonValue instance, string def) =>
        Registry.Validate(instance, DomainSchemaId, $"/$defs/{def}");

    public IReadOnlyList<SchemaViolation> ValidateRpc(JsonValue instance, string def) =>
        Registry.Validate(instance, RpcSchemaId, $"/$defs/{def}");
}

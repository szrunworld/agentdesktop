using AgentDesktop.Contracts;

namespace AgentDesktop.AI.Config;

/// <summary>
/// The configuration commands of contract v1 as RpcHandlers backed by one
/// ConfigStore. Params arrive validated against &lt;command&gt;_params; results
/// are checked by RpcRouter. Mirrors the Swift ConfigApplicationService.
/// </summary>
public sealed class ConfigApplicationService(ConfigStore store)
{
    public ConfigStore Store { get; } = store;

    public static readonly IReadOnlyList<string> Commands =
    [
        "ai.connections.list", "ai.connections.get", "ai.connections.create", "ai.connections.update",
        "ai.connections.disable", "ai.connections.delete", "ai.credentials.rotate",
        "ai.modelProfiles.list", "ai.modelProfiles.get", "ai.modelProfiles.create", "ai.modelProfiles.update",
        "ai.modelProfiles.disable", "ai.modelProfiles.delete",
        "ai.profiles.list", "ai.profiles.get", "ai.profiles.create", "ai.profiles.update",
        "ai.profiles.disable", "ai.profiles.delete",
        "ai.profiles.default.get", "ai.profiles.setDefault",
    ];

    /// <summary>
    /// Handlers for one caller. Idempotency records are scoped to the caller,
    /// so another caller's key never returns this caller's result (RPC-007).
    /// </summary>
    public IReadOnlyDictionary<string, RpcHandler> Handlers(string callerScope) =>
        Commands.ToDictionary(c => c, c => (RpcHandler)((req, ct) => Task.Run(() => Handle(req, callerScope), ct)),
                              StringComparer.Ordinal);

    public JsonValue Handle(RpcRequest req, string callerScope)
    {
        var p = req.Params;
        string Str(string k) => p[k]?.StringValue ?? "";
        int Int(string k) => (int)(p[k]?.IntValue ?? 0);
        var s = Store;
        JsonValue Mutate(Func<ConfigStore, JsonValue> body) => s.Idempotent(callerScope, req.Command, req.IdempotencyKey, p, body);
        var emptyPatch = JsonValue.Obj();

        return req.Command switch
        {
            "ai.connections.list" => s.List(ConfigResourceKind.Connection, p["limit"]?.IntValue, p["cursor"]?.StringValue,
                p["includeDisabled"]?.BoolValue ?? false),
            "ai.connections.get" => s.Get(ConfigResourceKind.Connection, Str("connectionId")),
            "ai.connections.create" => Mutate(st => st.CreateConnection(Str("name"), Str("protocol"), Str("baseUrl"),
                p["timeoutMs"]?.IntValue ?? 0, p["credential"]?["apiKey"]?.StringValue ?? "")),
            "ai.connections.update" => Mutate(st => st.UpdateConnection(Str("connectionId"), Int("expectedRevision"), p["patch"] ?? emptyPatch)),
            "ai.connections.disable" => Mutate(st => st.Disable(ConfigResourceKind.Connection, Str("connectionId"), Int("expectedRevision"))),
            "ai.connections.delete" => Mutate(st => st.Delete(ConfigResourceKind.Connection, Str("connectionId"), Int("expectedRevision"))),
            "ai.credentials.rotate" => Mutate(st => st.RotateCredential(Str("connectionId"), Int("expectedRevision"),
                p["credential"]?["apiKey"]?.StringValue ?? "")),

            "ai.modelProfiles.list" => s.List(ConfigResourceKind.ModelProfile, p["limit"]?.IntValue, p["cursor"]?.StringValue,
                p["includeDisabled"]?.BoolValue ?? false, p["connectionId"]?.StringValue),
            "ai.modelProfiles.get" => s.Get(ConfigResourceKind.ModelProfile, Str("modelProfileId")),
            "ai.modelProfiles.create" => Mutate(st => st.CreateModelProfile(p)),
            "ai.modelProfiles.update" => Mutate(st => st.UpdateModelProfile(Str("modelProfileId"), Int("expectedRevision"), p["patch"] ?? emptyPatch)),
            "ai.modelProfiles.disable" => Mutate(st => st.Disable(ConfigResourceKind.ModelProfile, Str("modelProfileId"), Int("expectedRevision"))),
            "ai.modelProfiles.delete" => Mutate(st => st.Delete(ConfigResourceKind.ModelProfile, Str("modelProfileId"), Int("expectedRevision"))),

            "ai.profiles.list" => s.List(ConfigResourceKind.GuiProfile, p["limit"]?.IntValue, p["cursor"]?.StringValue,
                p["includeDisabled"]?.BoolValue ?? false),
            "ai.profiles.get" => s.Get(ConfigResourceKind.GuiProfile, Str("guiProfileId")),
            "ai.profiles.create" => Mutate(st => st.CreateGuiProfile(p)),
            "ai.profiles.update" => Mutate(st => st.UpdateGuiProfile(Str("guiProfileId"), Int("expectedRevision"), p["patch"] ?? emptyPatch)),
            "ai.profiles.disable" => Mutate(st => st.Disable(ConfigResourceKind.GuiProfile, Str("guiProfileId"), Int("expectedRevision"))),
            "ai.profiles.delete" => Mutate(st => st.Delete(ConfigResourceKind.GuiProfile, Str("guiProfileId"), Int("expectedRevision"))),
            "ai.profiles.default.get" => s.DefaultProfile(),
            "ai.profiles.setDefault" => Mutate(st => st.SetDefault(p["guiProfileId"]?.StringValue, Int("expectedDefaultRevision"),
                (int?)p["expectedProfileRevision"]?.IntValue)),
            _ => throw new ContractError(ErrorCode.UnsupportedCommand, "not a configuration command"),
        };
    }
}

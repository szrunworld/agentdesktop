using System.Text;
using AgentDesktop.AI.Config;
using AgentDesktop.Contracts;
using Xunit;
using static AgentDesktop.AI.Tests.J;

namespace AgentDesktop.AI.Tests;

// Case IDs refer to docs/ai-gui/tests/cases.csv. Ported from
// Tests/AgentDesktopAITests/ConfigTests.swift: configuration service and
// its storage only; GUI runs and the network are not involved.

public class ConfigServiceTests
{
    [Fact]
    public async Task Cfg001_ThreeLayersStoredSeparately()
    {
        using var h = new Harness();
        var c = await h.CreateConnection();
        var m = await h.CreateModel(c);
        var g = await h.CreateGui(m);
        Assert.True(Rev(c) == 1 && Rev(m) == 1 && Rev(g) == 1);
        Assert.Equal(3, new[] { c["connectionId"]!.StringValue, m["modelProfileId"]!.StringValue, g["guiProfileId"]!.StringValue }.Distinct().Count());
        Assert.Equal(c["connectionId"], m["connectionId"]);
        Assert.Equal(I(1), m["connectionRevision"]);
        Assert.Equal(m["modelProfileId"], g["modelProfileId"]);
        Assert.Equal(I(1), g["modelProfileRevision"]);
        Assert.DoesNotContain("sk-", c["credentialRef"]!.StringValue!, StringComparison.Ordinal);
        Assert.Equal("https://ark.cn-beijing.volces.com/api/v3/", c["baseUrl"]!.StringValue);

        using var r = h.Reopened();
        Assert.Equal(c, await r.Ok("ai.connections.get", O(("connectionId", c["connectionId"]!))));
        Assert.Equal(m, await r.Ok("ai.modelProfiles.get", O(("modelProfileId", m["modelProfileId"]!))));
        Assert.Equal(g, await r.Ok("ai.profiles.get", O(("guiProfileId", g["guiProfileId"]!))));
    }

    [Fact]
    public async Task Cfg002_CasUpdateForEachLayer()
    {
        using var h = new Harness();
        var c = await h.CreateConnection();
        var m = await h.CreateModel(c);
        var g = await h.CreateGui(m);
        foreach (var (command, idField, obj) in new[] { ("ai.connections.update", "connectionId", c), ("ai.modelProfiles.update", "modelProfileId", m), ("ai.profiles.update", "guiProfileId", g) })
        {
            var a = await h.Ok(command, O((idField, obj[idField]!), ("expectedRevision", I(1)), ("patch", O(("name", S("A"))))));
            Assert.Equal(2, Rev(a));
            var b = await h.Call(command, O((idField, obj[idField]!), ("expectedRevision", I(1)), ("patch", O(("name", S("B"))))));
            Assert.Equal("CONFIG_CONFLICT", b["error"]?["code"]?.StringValue);
            Assert.Equal(2, b["error"]?["details"]?["currentRevision"]?.IntValue);
            Assert.Equal("A", (await h.Ok(command.Replace(".update", ".get", StringComparison.Ordinal), O((idField, obj[idField]!))))["name"]?.StringValue);
        }
    }

    [Fact]
    public async Task Cfg003_DefaultPointerHasItsOwnRevision()
    {
        using var h = new Harness();
        var m = await h.CreateModel(await h.CreateConnection());
        var p1 = await h.CreateGui(m, "P1");
        var p2 = await h.CreateGui(m, "P2");
        var d0 = await h.Ok("ai.profiles.default.get");
        Assert.True(d0["default"]?["revision"]?.IntValue == 1 && d0["default"]?["guiProfileId"]?.IsNull == true);
        var d1 = await h.Ok("ai.profiles.setDefault", O(("guiProfileId", p1["guiProfileId"]!), ("expectedDefaultRevision", I(1)), ("expectedProfileRevision", I(1))));
        Assert.Equal(2, d1["default"]?["revision"]?.IntValue);
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.profiles.setDefault", O(("guiProfileId", p2["guiProfileId"]!), ("expectedDefaultRevision", I(1)), ("expectedProfileRevision", I(1)))));
        await h.Ok("ai.profiles.update", O(("guiProfileId", p1["guiProfileId"]!), ("expectedRevision", I(1)), ("patch", O(("name", S("P1 renamed"))))));
        var d2 = await h.Ok("ai.profiles.default.get");
        Assert.Equal(2, d2["default"]?["revision"]?.IntValue);
        Assert.Equal(2, d2["resolvedProfile"]?["revision"]?.IntValue);
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.profiles.setDefault", O(("guiProfileId", p2["guiProfileId"]!), ("expectedDefaultRevision", I(2)), ("expectedProfileRevision", I(9)))));
        var cleared = await h.Ok("ai.profiles.setDefault", O(("guiProfileId", JsonValue.Null), ("expectedDefaultRevision", I(2))));
        Assert.True(cleared["resolvedProfile"]?.IsNull == true && cleared["default"]?["revision"]?.IntValue == 3);
    }

    [Fact]
    public async Task Cfg004_SnapshotsStayAndDisableBlocksNewBindings()
    {
        using var h = new Harness();
        var c = await h.CreateConnection();
        var m = await h.CreateModel(c);
        var p = await h.CreateGui(m);
        var id = p["guiProfileId"]!.StringValue!;
        var snapshot = h.Store.RevisionBody(ConfigResourceKind.GuiProfile, id, 1);
        await h.Ok("ai.profiles.update", O(("guiProfileId", p["guiProfileId"]!), ("expectedRevision", I(1)), ("patch", O(("promptVersion", S("2"))))));
        Assert.Equal(snapshot, h.Store.RevisionBody(ConfigResourceKind.GuiProfile, id, 1));
        Assert.Equal("1", snapshot?["promptVersion"]?.StringValue);

        await h.Ok("ai.profiles.disable", O(("guiProfileId", p["guiProfileId"]!), ("expectedRevision", I(2))));
        Assert.Equal("RESOURCE_DISABLED", await h.Err("ai.profiles.setDefault", O(("guiProfileId", p["guiProfileId"]!), ("expectedDefaultRevision", I(1)), ("expectedProfileRevision", I(3)))));
        await h.Ok("ai.modelProfiles.disable", O(("modelProfileId", m["modelProfileId"]!), ("expectedRevision", I(1))));
        Assert.Equal("RESOURCE_DISABLED", await h.Err("ai.profiles.create", Harness.GuiParams(m.Setting("revision", I(2)))));
        await h.Ok("ai.connections.disable", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1))));
        Assert.Equal("RESOURCE_DISABLED", await h.Err("ai.modelProfiles.create", O(
            ("name", S("x")), ("connectionId", c["connectionId"]!), ("connectionRevision", I(2)),
            ("modelId", S("m")), ("requestOptions", O()), ("maxOutputTokens", I(10)))));
        Assert.Empty((await h.Ok("ai.profiles.list"))["items"]!.ArrayValue!);
        Assert.Single((await h.Ok("ai.profiles.list", O(("includeDisabled", JsonValue.Bool(true)))))["items"]!.ArrayValue!);
    }

    [Fact]
    public async Task Cfg005_ReferenceProtectionAndTombstones()
    {
        using var h = new Harness();
        var c = await h.CreateConnection();
        var m = await h.CreateModel(c);
        var p = await h.CreateGui(m, "P");
        var f = await h.CreateGui(m, "F");
        var withFallback = await h.CreateGui(m, "W", [Harness.Ref(f)]);
        await h.Ok("ai.profiles.setDefault", O(("guiProfileId", p["guiProfileId"]!), ("expectedDefaultRevision", I(1)), ("expectedProfileRevision", I(1))));
        Assert.Equal("RESOURCE_IN_USE", await h.Err("ai.connections.delete", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)))));
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.connections.delete", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(9)))));
        Assert.Equal("RESOURCE_IN_USE", await h.Err("ai.modelProfiles.delete", O(("modelProfileId", m["modelProfileId"]!), ("expectedRevision", I(1)))));
        Assert.Equal("RESOURCE_IN_USE", await h.Err("ai.profiles.delete", O(("guiProfileId", p["guiProfileId"]!), ("expectedRevision", I(1)))));
        Assert.Equal("RESOURCE_IN_USE", await h.Err("ai.profiles.delete", O(("guiProfileId", f["guiProfileId"]!), ("expectedRevision", I(1)))));

        var busy = withFallback["guiProfileId"]!.StringValue!;
        h.Store.SetActiveRunCheck((kind, id) => kind == ConfigResourceKind.GuiProfile && id == busy);
        Assert.Equal("RESOURCE_IN_USE", await h.Err("ai.profiles.delete", O(("guiProfileId", withFallback["guiProfileId"]!), ("expectedRevision", I(1)))));
        h.Store.SetActiveRunCheck((_, _) => false);

        var q = await h.CreateGui(m, "Q");
        var before = (await h.Ok("ai.profiles.list", O(("limit", I(100)))))["items"]!.ArrayValue!.Count;
        var t = await h.Ok("ai.profiles.delete", O(("guiProfileId", q["guiProfileId"]!), ("expectedRevision", I(1))));
        Assert.True(t["resourceType"]?.StringValue == "guiAiProfile" && t["revision"]?.IntValue == 2);
        Assert.Equal("NOT_FOUND", await h.Err("ai.profiles.get", O(("guiProfileId", q["guiProfileId"]!))));
        var after = (await h.Ok("ai.profiles.list", O(("limit", I(100)))))["items"]!.ArrayValue!;
        Assert.Equal(before - 1, after.Count);
        Assert.DoesNotContain(after, x => x["guiProfileId"] == q["guiProfileId"]);
        Assert.Equal("Q", h.Store.RevisionBody(ConfigResourceKind.GuiProfile, q["guiProfileId"]!.StringValue!, 1)?["name"]?.StringValue);
        Assert.Equal("NOT_FOUND", await h.Err("ai.profiles.delete", O(("guiProfileId", q["guiProfileId"]!), ("expectedRevision", I(2)))));
    }

    [Fact]
    public async Task Cfg006_InvalidReferencesFailBeforeAnyUpstream()
    {
        using var h = new Harness();
        var c = await h.CreateConnection();
        var m = await h.CreateModel(c);
        Assert.Equal("NOT_FOUND", await h.Err("ai.profiles.create", Harness.GuiParams(m.Setting("modelProfileId", S("mp_missing")))));
        await h.Ok("ai.connections.update", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("patch", O(("timeoutMs", I(60000))))));
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.modelProfiles.create", O(
            ("name", S("stale")), ("connectionId", c["connectionId"]!), ("connectionRevision", I(1)),
            ("modelId", S("m")), ("requestOptions", O()), ("maxOutputTokens", I(10)))));
        Assert.Equal(1, (await h.Ok("ai.modelProfiles.get", O(("modelProfileId", m["modelProfileId"]!))))["connectionRevision"]?.IntValue);

        var a = await h.CreateGui(m, "A");
        var b = await h.CreateGui(m, "B", [Harness.Ref(a)]);
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.profiles.update", O(("guiProfileId", a["guiProfileId"]!), ("expectedRevision", I(1)),
            ("patch", O(("allowedFallbackProfileRefs", JsonValue.Array([Harness.Ref(b)])))))));
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.profiles.update", O(("guiProfileId", a["guiProfileId"]!), ("expectedRevision", I(1)),
            ("patch", O(("allowedFallbackProfileRefs", JsonValue.Array([Harness.Ref(a)])))))));
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.profiles.create", Harness.GuiParams(m, fallback: [Harness.Ref(a), Harness.Ref(b)])));
        Assert.Equal("CAPABILITY_MISMATCH", await h.Err("ai.profiles.create", Harness.GuiParams(m, adapter: "fixture_json_v1")));
        using var testBuild = new Harness(new ConfigOptions(AllowLoopbackHttp: true, AllowFixtureAdapter: true));
        var m2 = await testBuild.CreateModel(await testBuild.CreateConnection());
        await testBuild.Ok("ai.profiles.create", Harness.GuiParams(m2, adapter: "fixture_json_v1"));
    }

    [Fact]
    public async Task Cfg007_LimitsAndProtocols()
    {
        using var h = new Harness();
        var m = await h.CreateModel(await h.CreateConnection());
        foreach (var (k, v) in new[] { ("maxSteps", 21L), ("maxWallTimeMs", 120001), ("maxModelAttemptsPerStep", 3), ("maxTotalModelAttempts", 31),
                                       ("maxOutputTokens", 1025), ("maxWaitMs", 5001), ("maxSteps", 0), ("maxWaitMs", -1) })
        {
            var p = Harness.GuiParams(m).Setting("limits", Harness.Limits.Setting(k, I(v)));
            Assert.Equal("VALIDATION_ERROR", await h.Err("ai.profiles.create", p));
        }
        await h.Ok("ai.profiles.create", Harness.GuiParams(m).Setting("limits", Harness.Limits.Setting("maxSteps", I(1)).Setting("maxWaitMs", I(0))));
        // Over RPC the schema answers first; the service also refuses on its own.
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.connections.create", Harness.ConnectionParams().Setting("protocol", S("anthropic_messages"))));
        var e = Assert.Throws<ContractError>(() => h.Store.CreateConnection("x", "gemini_generate_content", "https://a.example/v1", 1000, "k"));
        Assert.Equal(ErrorCode.UnsupportedProtocol, e.Code);
    }

    [Fact]
    public async Task Cfg008_CapabilityEvidenceIsPerLayerAndPerRevision()
    {
        using var h = new Harness();
        var m = await h.CreateModel(await h.CreateConnection());
        var id = m["modelProfileId"]!.StringValue!;
        foreach (var layer in new[] { "network", "authModel", "imageInput", "guiContract" })
            Assert.Equal("unknown", m["capabilities"]?[layer]?["status"]?.StringValue);
        h.Store.RecordCapabilityEvidence(id, 1, CapabilityLayer.Network, "verified", "op-1", null);
        h.Store.RecordCapabilityEvidence(id, 1, CapabilityLayer.AuthModel, "verified", "op-1", null);
        h.Store.RecordCapabilityEvidence(id, 1, CapabilityLayer.ImageInput, "failed", "op-1", "CAPABILITY_MISMATCH");
        var now = await h.Ok("ai.modelProfiles.get", O(("modelProfileId", S(id))));
        Assert.Equal("verified", now["capabilities"]?["authModel"]?["status"]?.StringValue);
        Assert.Equal("failed", now["capabilities"]?["imageInput"]?["status"]?.StringValue);
        Assert.Equal("CAPABILITY_MISMATCH", now["capabilities"]?["imageInput"]?["reasonCode"]?.StringValue);
        Assert.Equal("unknown", now["capabilities"]?["guiContract"]?["status"]?.StringValue);
        var changed = await h.Ok("ai.modelProfiles.update", O(("modelProfileId", S(id)), ("expectedRevision", I(1)), ("patch", O(("modelId", S("other-model"))))));
        foreach (var layer in new[] { "network", "authModel", "imageInput", "guiContract" })
            Assert.Equal("unknown", changed["capabilities"]?[layer]?["status"]?.StringValue);
        Assert.Equal("verified", h.Store.RevisionBody(ConfigResourceKind.ModelProfile, id, 1)?["capabilities"]?["authModel"]?["status"]?.StringValue);
    }

    [Fact]
    public async Task ListsPageWithCursorsBoundToTheFilter()
    {
        using var h = new Harness();
        for (var i = 0; i < 25; i++) await h.CreateConnection($"c{i}");
        var first = await h.Ok("ai.connections.list");
        Assert.Equal(20, first["items"]!.ArrayValue!.Count);
        var cursor = first["nextCursor"]!;
        var second = await h.Ok("ai.connections.list", O(("cursor", cursor)));
        Assert.True(second["items"]!.ArrayValue!.Count == 5 && second["nextCursor"]!.IsNull);
        Assert.Equal(25, first["items"]!.ArrayValue!.Concat(second["items"]!.ArrayValue!).Select(x => x["name"]!.StringValue).Distinct().Count());
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.connections.list", O(("cursor", cursor), ("includeDisabled", JsonValue.Bool(true)))));
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.connections.list", O(("limit", I(101)))));
        Assert.Equal("VALIDATION_ERROR", await h.Err("ai.connections.list", O(("cursor", S("bm9wZQ==")))));
    }
}

public class IdempotencyTests
{
    // RPC-006 (configuration part): ten concurrent creates with one key.
    [Fact]
    public async Task Rpc006_ConcurrentSameKeyCreatesOnce()
    {
        using var h = new Harness();
        var p = Harness.ConnectionParams(apiKey: "sk-once", url: "https://ark.example/api/v3");
        var ids = await Task.WhenAll(Enumerable.Range(0, 10).Select(_ => Task.Run(async () =>
            (await h.Ok("ai.connections.create", p, "create-ark-1"))["connectionId"]!.StringValue!)));
        Assert.Single(ids.Distinct());
        Assert.Single((await h.Ok("ai.connections.list"))["items"]!.ArrayValue!);
        Assert.Single(h.Creds.StoredIds, id => id.StartsWith("cred_", StringComparison.Ordinal));
    }

    // RPC-007 (configuration part).
    [Fact]
    public async Task Rpc007_SameKeyDifferentBodyAndOtherCaller()
    {
        using var h = new Harness();
        var c = await h.CreateConnection("first", key: "shared-key-1");
        Assert.Equal("IDEMPOTENCY_CONFLICT", await h.Err("ai.connections.create", Harness.ConnectionParams("second", url: "https://ark.example/api/v3"), "shared-key-1"));
        // Same visible fields, different secret: still a different request.
        Assert.Equal("IDEMPOTENCY_CONFLICT", await h.Err("ai.connections.create", Harness.ConnectionParams("first", "sk-test-0002"), "shared-key-1"));
        Assert.Single((await h.Ok("ai.connections.list"))["items"]!.ArrayValue!);

        var other = new RpcRouter(h.Service.Handlers("other-caller"));
        var mine = await h.Call("ai.connections.create", Harness.ConnectionParams("theirs", "sk-other", "https://x.example/v1"), "shared-key-1", other);
        Assert.True(mine["ok"]?.BoolValue);
        Assert.NotEqual(c["connectionId"], mine["result"]?["connectionId"]);
    }

    [Fact]
    public async Task RecordsExpireAfterRetention()
    {
        using var h = new Harness();
        await h.CreateConnection("a", key: "expiring-key");
        h.Clock.Advance(24 * 3600 + 1);
        Assert.Equal("b", (await h.CreateConnection("b", key: "expiring-key"))["name"]?.StringValue);
    }

    [Fact]
    public async Task FailedValidationDoesNotPoisonTheKey()
    {
        using var h = new Harness();
        var c = await h.CreateConnection();
        var p = O(("connectionId", c["connectionId"]!), ("expectedRevision", I(5)), ("patch", O(("name", S("x")))));
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.connections.update", p, "upd-key-1"));
        await h.Ok("ai.connections.update", p.Setting("expectedRevision", I(1)), "upd-key-2");
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.connections.update", p, "upd-key-1"));
    }

    [Fact]
    public void DigestKeyIsCreatedOnceInTheCredentialStore()
    {
        var store = new InMemoryCredentialStore();
        var k1 = ConfigStore.LoadOrCreateDigestKey(store);
        var k2 = ConfigStore.LoadOrCreateDigestKey(store);
        Assert.Equal(32, k1.Length);
        Assert.Equal(k1, k2);
    }
}

public class CredentialTests
{
    // SEC-001 (local part): the key appears only in the credential store.
    [Fact]
    public async Task Sec001_CanaryNeverLeaves()
    {
        var canary1 = "sk-CANARY-" + Guid.NewGuid();
        var canary2 = "sk-CANARY-" + Guid.NewGuid();
        using var h = new Harness();
        var c = await h.CreateConnection(apiKey: canary1);
        await h.CreateGui(await h.CreateModel(c));
        var rotated = await h.Ok("ai.credentials.rotate", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("credential", O(("apiKey", S(canary2))))));
        await h.Ok("ai.connections.list");
        await h.Ok("ai.connections.get", O(("connectionId", c["connectionId"]!)));
        await h.Call("ai.credentials.rotate", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("credential", O(("apiKey", S(canary1))))));
        await h.Call("ai.connections.create", Harness.ConnectionParams("x", canary1, "http://evil.example/v1").Setting("leak", S(canary2)));
        await h.Call("ai.connections.create", Harness.ConnectionParams("x", canary1, "https://evil.example/v1/chat/completions"));
        Assert.NotEqual(c["credentialRef"], rotated["credentialRef"]);
        lock (h.Responses)
            foreach (var text in h.Responses) Assert.DoesNotContain("CANARY", text, StringComparison.Ordinal);
        var files = h.Files().ToList();
        Assert.Contains(files, f => f.Name == "config.sqlite");
        var needle = Encoding.UTF8.GetBytes("CANARY");
        foreach (var (name, bytes) in files)
            Assert.True(bytes.AsSpan().IndexOf(needle) < 0, $"{name} holds the key");
        Assert.Equal(canary2, h.Store.ResolveSecret(rotated["credentialRef"]!.StringValue!));
    }

    // SEC-002 (local part): survives restart; a missing secret never falls back.
    [Fact]
    public async Task Sec002_SecretSurvivesRestartAndMissingSecretFails()
    {
        using var h = new Harness();
        var c = await h.CreateConnection(apiKey: "sk-persist");
        var credentialId = c["credentialRef"]!.StringValue!;
        using var restarted = h.Reopened();
        Assert.Equal("sk-persist", restarted.Store.ResolveSecret(credentialId));
        h.Creds.Drop(credentialId);
        Assert.Equal(ErrorCode.CredentialRequired, Assert.Throws<ContractError>(() => restarted.Store.ResolveSecret(credentialId)).Code);
        Assert.Equal(ErrorCode.CredentialRequired, Assert.Throws<ContractError>(() => restarted.Store.ResolveSecret("cred_unknown")).Code);
        h.Creds.Fail(InMemoryCredentialStore.Op.Read);
        Assert.Equal(ErrorCode.CredentialRequired, Assert.Throws<ContractError>(() => restarted.Store.ResolveSecret(credentialId)).Code);
    }

    // SEC-004 (storage part): rotation revokes the old identity for good.
    [Fact]
    public async Task Sec004_RotationRevokesAndNotifies()
    {
        using var h = new Harness();
        var revoked = new List<string>();
        h.Store.OnCredentialRevoked(id => { lock (revoked) revoked.Add(id); });
        var c = await h.CreateConnection(apiKey: "sk-K1");
        var k1 = c["credentialRef"]!.StringValue!;
        var r = await h.Ok("ai.credentials.rotate", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("credential", O(("apiKey", S("sk-K2"))))));
        var k2 = r["credentialRef"]!.StringValue!;
        Assert.True(Rev(r) == 2 && k1 != k2);
        Assert.Equal([k1], revoked);
        Assert.DoesNotContain(k1, h.Creds.StoredIds);
        Assert.Equal(ErrorCode.CredentialRevoked, Assert.Throws<ContractError>(() => h.Store.ResolveSecret(k1)).Code);
        Assert.Equal("sk-K2", h.Store.ResolveSecret(k2));
        var cid = c["connectionId"]!.StringValue!;
        Assert.Equal(k1, h.Store.CredentialId(cid, 1));
        Assert.Equal(k2, h.Store.CredentialId(cid, 2));
        Assert.Equal("CONFIG_CONFLICT", await h.Err("ai.credentials.rotate", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("credential", O(("apiKey", S("sk-K3")))))));
        Assert.Equal(new[] { k2 }, h.Creds.StoredIds.ToArray());
    }

    [Fact]
    public async Task SecretWriteFailureLeavesNothing()
    {
        using var h = new Harness();
        h.Creds.Fail(InMemoryCredentialStore.Op.Write);
        var v = await h.Call("ai.connections.create", Harness.ConnectionParams("x", "sk-x", "https://a.example/v1"), "write-fail-key");
        Assert.True(v["error"]?["code"]?.StringValue == "INTERNAL_ERROR" && v["error"]?["retryable"]?.BoolValue == true);
        h.Creds.Fail(InMemoryCredentialStore.Op.Write, false);
        Assert.Empty((await h.Ok("ai.connections.list"))["items"]!.ArrayValue!);
        await h.CreateConnection("x", "sk-x", "https://a.example/v1", "write-fail-key");
    }

    [Fact]
    public async Task CrashAfterSecretWriteIsRecovered()
    {
        using var h = new Harness();
        h.Store.SetFaultHook(p => { if (p == ConfigFaultPoint.AfterSecretWrite) throw new SimulatedCrashException(); });
        await h.Call("ai.connections.create", Harness.ConnectionParams("x", "sk-orphan", "https://a.example/v1"), "crash-key-1");
        Assert.Single(h.Creds.StoredIds);
        h.Store.Dispose();
        using var r = h.Reopened();
        r.Store.Recover();
        Assert.Empty(h.Creds.StoredIds);
        Assert.Empty((await r.Ok("ai.connections.list"))["items"]!.ArrayValue!);
        var again = await r.Call("ai.connections.create", Harness.ConnectionParams("x", "sk-orphan", "https://a.example/v1"), "crash-key-1");
        Assert.Equal("INTERNAL_ERROR", again["error"]?["code"]?.StringValue);
    }

    [Fact]
    public async Task CrashBeforeOutboxIsReplayed()
    {
        using var h = new Harness();
        var c = await h.CreateConnection(apiKey: "sk-old");
        var k1 = c["credentialRef"]!.StringValue!;
        h.Store.SetFaultHook(p => { if (p == ConfigFaultPoint.AfterActivate) throw new SimulatedCrashException(); });
        await h.Call("ai.credentials.rotate", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("credential", O(("apiKey", S("sk-new"))))));
        Assert.Contains(k1, h.Creds.StoredIds);
        Assert.Equal(ErrorCode.CredentialRevoked, Assert.Throws<ContractError>(() => h.Store.ResolveSecret(k1)).Code);
        h.Store.Dispose();
        using var r = h.Reopened();
        var revoked = new List<string>();
        r.Store.OnCredentialRevoked(revoked.Add);
        r.Store.Recover();
        Assert.Equal([k1], revoked);
        Assert.DoesNotContain(k1, h.Creds.StoredIds);
    }

    [Fact]
    public async Task FailedSecretCleanupStaysPendingButRevoked()
    {
        using var h = new Harness();
        var c = await h.CreateConnection(apiKey: "sk-old");
        var k1 = c["credentialRef"]!.StringValue!;
        h.Creds.Fail(InMemoryCredentialStore.Op.Delete);
        await h.Ok("ai.credentials.rotate", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1)), ("credential", O(("apiKey", S("sk-new"))))));
        Assert.Contains(k1, h.Creds.StoredIds);
        Assert.Equal(ErrorCode.CredentialRevoked, Assert.Throws<ContractError>(() => h.Store.ResolveSecret(k1)).Code);
        h.Creds.Fail(InMemoryCredentialStore.Op.Delete, false);
        Assert.Equal(1, h.Store.ApplyOutbox());
        Assert.DoesNotContain(k1, h.Creds.StoredIds);
    }

    [Fact]
    public async Task DeletingAConnectionRevokesItsCredential()
    {
        using var h = new Harness();
        var c = await h.CreateConnection(apiKey: "sk-gone");
        await h.Ok("ai.connections.delete", O(("connectionId", c["connectionId"]!), ("expectedRevision", I(1))));
        Assert.Empty(h.Creds.StoredIds);
        Assert.Equal("revoked", h.Store.CredentialState(c["credentialRef"]!.StringValue!));
    }

    // WIN-00x (credential part): DPAPI for the current user under a private ACL.
    [WindowsFact]
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    public void DpapiStoreRoundTripUnderAPrivateAcl()
    {
        var dir = Path.Combine(Path.GetTempPath(), "adcred-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new DpapiCredentialStore(dir);
            var id = "cred_test:" + Guid.NewGuid().ToString("N");
            store.Write(id, "sk-dpapi-CANARY");
            Assert.Equal("sk-dpapi-CANARY", store.Read(id));
            store.Write(id, "sk-dpapi-CANARY-2");
            Assert.Equal("sk-dpapi-CANARY-2", store.Read(id));
            foreach (var f in Directory.GetFiles(dir))
                Assert.True(File.ReadAllBytes(f).AsSpan().IndexOf(Encoding.UTF8.GetBytes("CANARY")) < 0, "the file holds the plain key");
            var acl = new DirectoryInfo(dir).GetAccessControl();
            Assert.True(acl.AreAccessRulesProtected, "inheritance is cut");
            var me = System.Security.Principal.WindowsIdentity.GetCurrent().User!;
            var rules = acl.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier))
                .Cast<System.Security.AccessControl.FileSystemAccessRule>().ToList();
            Assert.NotEmpty(rules);
            Assert.All(rules, r => Assert.Equal(me, r.IdentityReference));
            store.Delete(id);
            Assert.Null(store.Read(id));
            store.Delete(id);

            // The whole service on DPAPI: create, restart, resolve.
            var dbDir = Path.Combine(dir, "db");
            Directory.CreateDirectory(dbDir);
            var key = ConfigStore.LoadOrCreateDigestKey(store);
            string credentialId;
            using (var s1 = new ConfigStore(Path.Combine(dbDir, "c.sqlite"), store, key))
                credentialId = s1.CreateConnection("Ark", "openai_chat", "https://a.example/v1", 1000, "sk-real-dpapi")["credentialRef"]!.StringValue!;
            using var s2 = new ConfigStore(Path.Combine(dbDir, "c.sqlite"), store, ConfigStore.LoadOrCreateDigestKey(store));
            Assert.Equal("sk-real-dpapi", s2.ResolveSecret(credentialId));
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    [NonWindowsFact]
    public void DpapiStoreRefusesOtherPlatforms()
    {
#pragma warning disable CA1416 // The point is that it throws off Windows.
        Assert.Throws<PlatformNotSupportedException>(() => new DpapiCredentialStore(Path.GetTempPath()));
#pragma warning restore CA1416
    }
}

public class EndpointTests
{
    // SEC-005 (service part).
    [Theory]
    [InlineData("https://api.example.com/v1", true, "https://api.example.com/v1/")]
    [InlineData("https://ark.cn-beijing.volces.com/api/v3/", true, "https://ark.cn-beijing.volces.com/api/v3/")]
    [InlineData("https://api.example.com", true, "https://api.example.com/")]
    [InlineData("http://127.0.0.1:8080/v1", true, "http://127.0.0.1:8080/v1/")]
    [InlineData("http://[::1]:9000", true, "http://[::1]:9000/")]
    [InlineData("http://api.example.com/v1", false, "")]
    [InlineData("https://u:p@api.example.com/v1", false, "")]
    [InlineData("https://api.example.com/v1?x=1", false, "")]
    [InlineData("https://api.example.com/v1#f", false, "")]
    [InlineData("ftp://api.example.com", false, "")]
    [InlineData("https://api.example.com/v1/chat/completions", false, "")]
    [InlineData("https://api.example.com/v1/chat/completions/", false, "")]
    [InlineData("api.example.com/v1", false, "")]
    public void Sec005_Rules(string url, bool ok, string normalized)
    {
        if (ok) Assert.Equal(normalized, EndpointPolicy.Normalize(url, true).AbsoluteUri);
        else Assert.Equal(ErrorCode.ValidationError, Assert.Throws<ContractError>(() => EndpointPolicy.Normalize(url, true)).Code);
    }

    [Fact]
    public void LoopbackHttpNeedsTheLocalOption() =>
        Assert.Throws<ContractError>(() => EndpointPolicy.Normalize("http://127.0.0.1:8080", false));

    [Fact]
    public void LocalhostMustResolveToLoopback()
    {
        Assert.Throws<ContractError>(() => EndpointPolicy.Normalize("http://localhost:11434", true, _ => ["127.0.0.1", "10.0.0.5"]));
        Assert.Equal("http://localhost:11434/", EndpointPolicy.Normalize("http://localhost:11434", true, _ => ["127.0.0.1", "::1"]).AbsoluteUri);
    }

    // TRN-002 (path part): one chat/completions, base path kept.
    [Theory]
    [InlineData("https://ark.cn-beijing.volces.com/api/v3", "https://ark.cn-beijing.volces.com/api/v3/chat/completions")]
    [InlineData("https://ark.cn-beijing.volces.com/api/v3/", "https://ark.cn-beijing.volces.com/api/v3/chat/completions")]
    [InlineData("https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions")]
    public void ChatCompletionsKeepsTheBasePath(string baseUrl, string want) =>
        Assert.Equal(want, EndpointPolicy.ChatCompletionsUrl(EndpointPolicy.Normalize(baseUrl, false)).AbsoluteUri);

    [Fact]
    public async Task RefusalNamesTheFieldNotTheValue()
    {
        using var h = new Harness();
        var v = await h.Call("ai.connections.create", Harness.ConnectionParams(url: "https://secret-host.example/v1/chat/completions"));
        Assert.Equal("VALIDATION_ERROR", v["error"]?["code"]?.StringValue);
        Assert.Equal("/params/baseUrl", v["error"]?["details"]?["fieldErrors"]?.ArrayValue?[0]["path"]?.StringValue);
        Assert.DoesNotContain("secret-host", v.Encoded(), StringComparison.Ordinal);
    }
}

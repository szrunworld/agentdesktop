using System.Reflection;
using AgentDesktop.Contracts;
using Xunit;

namespace AgentDesktop.GUI.Tests;

// Ported from Tests/AgentDesktopGUITests/CodecCoordinateTests.swift and
// CodecActionTests.swift: the checks that are not plain input → output
// pairs (those live in the shared golden).

internal static class Fx
{
    public static readonly ObservationStamp Stamp = new("sess-A", "desktopA", "snapS1", 1, 1);
    public static readonly TargetIdentity Target = new("com.agentdesktop.neutral-form", 4242, "ps-1", "w-1", 3, "windows-uia",
                                                       new Rect(-1440, 120, 800, 500));

    public static ScreenshotDescriptor Shot(string id = "shot-1", ScreenshotTransform? t = null) =>
        new(id, "art-" + id, new string('a', 64), "image/png", "t1", new GuiAffineTransform(0.5, 0, 0, 0.5, -1440, 120),
            t ?? ScreenshotTransform.Pipeline(new Size(1600, 1000)));

    public static Observation Observation(params ScreenshotDescriptor[] shots) =>
        new("obs-1", Stamp, Target, DateTimeOffset.FromUnixTimeSeconds(1_791_000_000), shots.Length == 0 ? [Shot()] : shots);

    public static readonly CodecContext Context = new(ScreenshotTransform.Pipeline(new Size(1600, 1000)), 2000);
    public static readonly UITarsCodec Uitars = new(CoordinateProtocol.Normalized1000);
    public static readonly FixtureJsonCodec Fixture = new(CoordinateProtocol.Normalized1000);

    public static ErrorCode? Code(Action a)
    {
        try { a(); return null; }
        catch (ContractError e) { return e.Code; }
    }
}

public class CodecTests
{
    [Fact]
    public void Coo007_SwappingBAndCIsVisible()
    {
        var t = new GuiAffineTransform(1.2, 0.3, -0.4, 0.9, 15, -7);
        var q = t.Apply(new Point(10, 20));
        Assert.Equal(1.2 * 10 - 0.4 * 20 + 15, q.X, 1e-9);
        Assert.Equal(0.3 * 10 + 0.9 * 20 - 7, q.Y, 1e-9);
    }

    [Fact]
    public void ScreenshotTransformRoundTripsThroughJson()
    {
        var t = ScreenshotTransform.Pipeline(new Size(2400, 1600), new Rect(200, 300, 1200, 800), new Size(600, 400), new Insets(20, 40, 20, 40));
        Assert.Empty(ContractBundle.Shared.ValidateDomain(t.Json, "ScreenshotTransform"));
        Assert.Equal(t, ScreenshotTransform.FromJson(t.Json));
    }

    [Fact]
    public void ObservationEncodesToTheContract() =>
        Assert.Empty(ContractBundle.Shared.ValidateDomain(Fx.Observation().Json, "Observation"));

    [Fact]
    public void Gui002_EveryGoldenSuggestionBecomesAValidProposal()
    {
        var suggestions = Golden.File_["codec"]!["suggestions"]!.ArrayValue!
            .Where(s => s["adapterId"]!.StringValue == "uitars_v1" && s["protocol"]!.StringValue == "normalized_1000"
                        && s["expect"]!["ok"] is not null && s["maxWaitMs"] is null);
        var n = 0;
        foreach (var s in suggestions)
        {
            var (p, _) = new ProposalFactory().Propose(Fx.Uitars, s["reply"]!.StringValue!, "run-1", 0, "att-1",
                                                       Fx.Observation(), "shot-1", 2000);
            Assert.Empty(ContractBundle.Shared.ValidateDomain(p.Json, "GuiProposal"));
            n++;
        }
        Assert.True(n >= 20);
    }

    [Fact]
    public void ThoughtIsKeptButNeverParsed()
    {
        var d = Fx.Uitars.Decode("Thought: Action items: click(start_box='(9,9)') later\nAction: finished(content='ok')", Fx.Context);
        Assert.Equal(new GuiProposalBody.Finish("ok"), d.Body);
        Assert.Contains("Action items", d.Thought);
    }

    [Fact]
    public void ActionSpaceNamesOnlyV1Actions()
    {
        var text = UITarsCodec.ActionSpace(CoordinateProtocol.Normalized1000);
        foreach (var name in new[] { "click(", "type(", "hotkey(", "scroll(", "wait(", "finished(", "call_user(" }) Assert.Contains(name, text);
        foreach (var name in new[] { "drag(", "left_double(", "right_single(", "element=" }) Assert.DoesNotContain(name, text);
    }

    [Fact]
    public void ProductionRegistryRefusesTheFixtureAdapter()
    {
        var production = new GuiCodecRegistry();
        Assert.False(production.FixtureAdapterEnabled);
        Assert.Equal([GuiAdapterId.UitarsV1], production.AvailableAdapters);
        Assert.Equal(ErrorCode.CapabilityMismatch, Fx.Code(() => production.Codec("fixture_json_v1", "normalized_1000")));
    }

    // GUI-001: codecs hold no capability; a proposal carries no authority.
    [Fact]
    public void Gui001_NoCapabilitiesAndNoAuthorityFields()
    {
        foreach (var type in new[] { typeof(UITarsCodec), typeof(FixtureJsonCodec) })
        {
            var fields = type.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            Assert.All(fields, f => Assert.Equal(typeof(AdapterProvenance), f.FieldType));
        }
        var (p, _) = new ProposalFactory().Propose(Fx.Uitars, "Action: click(start_box='(500,500)')", "run-1", 3, "att-9",
                                                   Fx.Observation(), "shot-1", 2000);
        var keys = p.Json.ObjectMembers!.Select(m => m.Key).ToHashSet();
        Assert.True(keys.SetEquals(["proposalId", "runId", "stepIndex", "inferenceAttemptId", "desktopId", "snapshotId",
                                    "bindingEpoch", "runGeneration", "screenshotId", "provenance", "kind", "action"]));
    }

    // GUI-004 (codec side): the codec maps with the chosen screenshot's own transform.
    [Fact]
    public void Gui004_UsesTheBoundScreenshotsTransform()
    {
        var cropped = ScreenshotTransform.Pipeline(new Size(1600, 1000), new Rect(200, 100, 1000, 600), new Size(500, 300));
        var obs = Fx.Observation(Fx.Shot("shot-1"), Fx.Shot("shot-2", cropped));
        var (p, _) = new ProposalFactory().Propose(new UITarsCodec(CoordinateProtocol.ImagePixels), "Action: click(start_box='(250,150)')",
                                                   "run-1", 0, "att-1", obs, "shot-2", 2000);
        var click = Assert.IsType<GuiAction.Click>(Assert.IsType<GuiProposalBody.Action>(p.Body).Value);
        Assert.Equal(700, click.SourcePixel.X, 1e-6);
        Assert.Equal(400, click.SourcePixel.Y, 1e-6);
        var d = CoordinateMapper.DesktopPoint(click.SourcePixel, obs.Screenshot("shot-2")!);
        Assert.Equal(-1090, d.X, 1e-6);
        Assert.Equal(320, d.Y, 1e-6);
        Assert.Equal(Fx.Stamp, p.Stamp);
    }

    // GUI-002: typed text is redacted in ordinary descriptions.
    [Fact]
    public void Gui002_TypedTextIsRedacted()
    {
        const string secret = "MAC-001-A 的密码是 hunter2";
        var (p, _) = new ProposalFactory().Propose(Fx.Uitars, $"Action: type(content='{secret}')", "run-1", 0, "att-1",
                                                   Fx.Observation(), "shot-1", 2000);
        Assert.DoesNotContain("hunter2", p.RedactedDescription);
        Assert.Contains($"<{TextMeasure.Graphemes(secret)} chars>", p.RedactedDescription);
        Assert.DoesNotContain("密码", p.Body.RedactedDescription);
    }

    [Fact]
    public void FactoryRefusesOutOfRangeStepAndPoints()
    {
        var obs = Fx.Observation();
        var f = new ProposalFactory();
        Assert.Equal(ErrorCode.ValidationError,
            Fx.Code(() => f.Make("run-1", 20, "att-1", obs, "shot-1", Fx.Uitars.Provenance, new GuiProposalBody.Finish("x"))));
        Assert.Equal(ErrorCode.CoordinateOutOfBounds,
            Fx.Code(() => f.Make("run-1", 0, "att-1", obs, "shot-1", Fx.Uitars.Provenance,
                                 new GuiProposalBody.Action(new GuiAction.Click(new Point(1600, 1))))));
    }

    [Fact]
    public void WaitBoundsFollowTheProfile()
    {
        var zero = new CodecContext(Fx.Context.Transform, 0);
        Assert.Equal(new GuiProposalBody.Wait(0), Fx.Uitars.Decode("Action: wait()", zero).Body);
        var wide = new CodecContext(Fx.Context.Transform, 5000);
        Assert.Null(Fx.Code(() => Fx.Fixture.Decode("""{"kind":"wait","waitMs":5000}""", wide)));
        Assert.Equal(ErrorCode.LimitExceeded, Fx.Code(() => Fx.Fixture.Decode("""{"kind":"wait","waitMs":5001}""", wide)));
    }

    [Fact]
    public void KeyEqualityIsByValue() =>
        Assert.Equal(new GuiAction.Key(["Control", "C"]), Fx.Uitars.Decode("Action: hotkey(key='ctrl c')", Fx.Context).Body is
            GuiProposalBody.Action { Value: GuiAction.Key k } ? k : null);
}

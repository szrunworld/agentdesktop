using System.Globalization;
using System.Text;
using AgentDesktop.Contracts;

namespace AgentDesktop.GUI;

// GUI proposals of contract v1 (spec §04, §06.2, §08.4), mirroring
// Sources/AgentDesktopContracts/Domain/GuiProposal.swift. A proposal is a
// suggestion: it carries no execution authority.

public enum GuiAdapterId { UitarsV1, FixtureJsonV1 }

public static class GuiAdapterIds
{
    public static string Wire(this GuiAdapterId id) => id == GuiAdapterId.UitarsV1 ? "uitars_v1" : "fixture_json_v1";

    public static GuiAdapterId? FromWire(string? s) => s switch
    {
        "uitars_v1" => GuiAdapterId.UitarsV1,
        "fixture_json_v1" => GuiAdapterId.FixtureJsonV1,
        _ => null,
    };
}

public sealed record AdapterProvenance(GuiAdapterId AdapterId, string AdapterVersion, string PromptVersion,
                                       string ParserVersion, CoordinateProtocol CoordinateProtocol)
{
    public JsonValue Json => JsonValue.Obj(
        ("adapterId", JsonValue.String(AdapterId.Wire())), ("adapterVersion", JsonValue.String(AdapterVersion)),
        ("promptVersion", JsonValue.String(PromptVersion)), ("parserVersion", JsonValue.String(ParserVersion)),
        ("coordinateProtocol", JsonValue.String(CoordinateProtocol.Wire())));
}

public enum GuiActionKind { Click, Type, Key, Scroll }

public enum ScrollDirection { Up, Down, Left, Right }

public static class ScrollDirections
{
    public static string Wire(this ScrollDirection d) => d.ToString().ToLowerInvariant();

    public static ScrollDirection? FromWire(string? s) => s switch
    {
        "up" => ScrollDirection.Up, "down" => ScrollDirection.Down,
        "left" => ScrollDirection.Left, "right" => ScrollDirection.Right,
        _ => null,
    };
}

/// <summary>The key names a <c>key</c> action may use (domain.schema.json KeyAction).</summary>
public static class GuiKeys
{
    public static readonly IReadOnlySet<string> Named = new HashSet<string>(StringComparer.Ordinal)
    {
        "Shift", "Control", "Alt", "Meta", "Enter", "Tab", "Escape", "Backspace", "Delete",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Space",
    };
    public const int MaxKeys = 4;

    public static bool IsValid(string key)
    {
        if (Named.Contains(key)) return true;
        if (TextMeasure.Graphemes(key) != 1) return false;
        var s = key.EnumerateRunes().First().Value;
        return s is >= 'A' and <= 'Z' or >= '0' and <= '9';
    }
}

/// <summary>Text measured the way Swift's String.count does: extended grapheme clusters.</summary>
public static class TextMeasure
{
    public static int Graphemes(string s) => new StringInfo(s).LengthInTextElements;
    public static int Scalars(string s) => s.EnumerateRunes().Count();
}

public abstract record GuiAction
{
    public const int MaxTypeLength = 65_536;

    /// <summary>Left button only in v1; the point is in source screenshot pixels.</summary>
    public sealed record Click(Point SourcePixel) : GuiAction;
    /// <summary>Sensitive: never put the text into ordinary logs or run events.</summary>
    public sealed record Type(string Text) : GuiAction;
    public sealed record Key(IReadOnlyList<string> Keys) : GuiAction
    {
        public bool Equals(Key? other) => other is not null && Keys.SequenceEqual(other.Keys, StringComparer.Ordinal);
        public override int GetHashCode() => Keys.Aggregate(17, (h, k) => h * 31 + StringComparer.Ordinal.GetHashCode(k));
    }
    public sealed record Scroll(Point SourcePixel, ScrollDirection Direction, int AmountPixels) : GuiAction;

    public GuiActionKind Kind => this switch
    {
        Click => GuiActionKind.Click,
        Type => GuiActionKind.Type,
        Key => GuiActionKind.Key,
        _ => GuiActionKind.Scroll,
    };

    public JsonValue Json => this switch
    {
        Click c => JsonValue.Obj(("type", JsonValue.String("click")), ("x", JsonValue.Double(c.SourcePixel.X)),
                                 ("y", JsonValue.Double(c.SourcePixel.Y)), ("button", JsonValue.String("left"))),
        Type t => JsonValue.Obj(("type", JsonValue.String("type")), ("text", JsonValue.String(t.Text))),
        Key k => JsonValue.Obj(("type", JsonValue.String("key")), ("keys", JsonValue.Array(k.Keys.Select(JsonValue.String)))),
        Scroll s => JsonValue.Obj(("type", JsonValue.String("scroll")), ("x", JsonValue.Double(s.SourcePixel.X)),
                                  ("y", JsonValue.Double(s.SourcePixel.Y)), ("direction", JsonValue.String(s.Direction.Wire())),
                                  ("amountPixels", JsonValue.Int(s.AmountPixels))),
        _ => throw new InvalidOperationException(),
    };

    /// <summary>For ordinary logs and events: typed text is reduced to its length.</summary>
    public string RedactedDescription => this switch
    {
        Click c => $"click {c.SourcePixel}",
        Type t => $"type <{TextMeasure.Graphemes(t.Text)} chars>",
        Key k => "key " + string.Join("+", k.Keys),
        Scroll s => string.Create(CultureInfo.InvariantCulture, $"scroll {s.Direction.Wire()} {s.AmountPixels}px at {s.SourcePixel}"),
        _ => "",
    };
}

public abstract record GuiProposalBody
{
    public sealed record Action(GuiAction Value) : GuiProposalBody;
    public sealed record Wait(int Milliseconds) : GuiProposalBody;
    /// <summary>Asks the verifier to look; it can never mark the run succeeded.</summary>
    public sealed record Finish(string Reason) : GuiProposalBody;
    public sealed record NeedsUser(string ReasonCode, string Message) : GuiProposalBody;

    public string KindName => this switch
    {
        Action => "action",
        Wait => "wait",
        Finish => "finish",
        _ => "needs_user",
    };

    /// <summary>The body as the tail of GuiProposal's wire form.</summary>
    public IEnumerable<(string, JsonValue)> WireMembers()
    {
        yield return ("kind", JsonValue.String(KindName));
        switch (this)
        {
            case Action a: yield return ("action", a.Value.Json); break;
            case Wait w: yield return ("waitMs", JsonValue.Int(w.Milliseconds)); break;
            case Finish f: yield return ("reason", JsonValue.String(f.Reason)); break;
            case NeedsUser n:
                yield return ("reasonCode", JsonValue.String(n.ReasonCode));
                yield return ("message", JsonValue.String(n.Message));
                break;
        }
    }

    public JsonValue Json => JsonValue.Obj([.. WireMembers()]);

    public string RedactedDescription => this switch
    {
        Action a => a.Value.RedactedDescription,
        Wait w => string.Create(CultureInfo.InvariantCulture, $"wait {w.Milliseconds}ms"),
        Finish => "finish",
        NeedsUser n => $"needs_user {n.ReasonCode}",
        _ => "",
    };
}

public sealed record GuiProposal(string ProposalId, string RunId, int StepIndex, string InferenceAttemptId,
                                 ObservationStamp Stamp, string ScreenshotId, AdapterProvenance Provenance, GuiProposalBody Body)
{
    /// <summary>The wire form (domain.schema.json#/$defs/GuiProposal). Holds typed text; log RedactedDescription instead.</summary>
    public JsonValue Json
    {
        get
        {
            var m = new List<(string, JsonValue)>
            {
                ("proposalId", JsonValue.String(ProposalId)), ("runId", JsonValue.String(RunId)),
                ("stepIndex", JsonValue.Int(StepIndex)), ("inferenceAttemptId", JsonValue.String(InferenceAttemptId)),
                ("desktopId", JsonValue.String(Stamp.DesktopId)), ("snapshotId", JsonValue.String(Stamp.SnapshotId)),
                ("bindingEpoch", JsonValue.Int(Stamp.BindingEpoch)), ("runGeneration", JsonValue.Int(Stamp.RunGeneration)),
                ("screenshotId", JsonValue.String(ScreenshotId)), ("provenance", Provenance.Json),
            };
            m.AddRange(Body.WireMembers());
            return JsonValue.Obj([.. m]);
        }
    }

    public string RedactedDescription => new StringBuilder()
        .Append(CultureInfo.InvariantCulture, $"proposal {ProposalId} run {RunId} step {StepIndex} snapshot {Stamp.SnapshotId}: ")
        .Append(Body.RedactedDescription).ToString();
}

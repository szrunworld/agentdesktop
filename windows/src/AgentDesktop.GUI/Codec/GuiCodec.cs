using System.Globalization;
using System.Text;
using AgentDesktop.Contracts;

namespace AgentDesktop.GUI;

/// <summary>What a codec needs to read one reply; it comes from the observation and the bound profile, never the model.</summary>
public sealed record CodecContext(ScreenshotTransform Transform, int MaxWaitMs);

/// <summary>One reply, decoded: exactly one suggestion, coordinates already in source pixels.</summary>
public sealed record DecodedSuggestion(GuiProposalBody Body, string? Thought);

/// <summary>Turns a complete model reply into one suggestion. Holds no screen, input or capture capability.</summary>
public interface IGuiActionCodec
{
    AdapterProvenance Provenance { get; }
    DecodedSuggestion Decode(string modelOutput, CodecContext context);
}

internal static class CodecLimits
{
    public const int MaxReplyScalars = 140_000;
    public const int MaxReasonLength = 512;
    public const int MaxReasonCodeLength = 96;
}

internal static class SuggestionRules
{
    public static ContractError InvalidAction(string message) => new(ErrorCode.InvalidAction, message);

    public static void CheckType(string text)
    {
        if (TextMeasure.Graphemes(text) > GuiAction.MaxTypeLength)
            throw InvalidAction($"type text is longer than {GuiAction.MaxTypeLength}");
        foreach (var r in text.EnumerateRunes())
            if (Rune.GetUnicodeCategory(r) == UnicodeCategory.Control && r.Value != '\n' && r.Value != '\t')
                throw InvalidAction("type text holds a control character");
    }

    public static void CheckKeys(IReadOnlyList<string> keys)
    {
        if (keys.Count is < 1 or > GuiKeys.MaxKeys) throw InvalidAction($"key needs 1 to {GuiKeys.MaxKeys} keys");
        if (keys.Distinct(StringComparer.Ordinal).Count() != keys.Count) throw InvalidAction("key repeats a key");
        foreach (var k in keys) if (!GuiKeys.IsValid(k)) throw InvalidAction($"key \"{k}\" is not allowed");
    }

    public static void CheckWait(long ms, long max)
    {
        if (ms < 0) throw InvalidAction("wait must not be negative");
        if (ms > max || ms > 5000) throw new ContractError(ErrorCode.LimitExceeded, $"wait is longer than {Math.Min(max, 5000)}ms");
    }

    public static void CheckReason(string s, string what, int max = CodecLimits.MaxReasonLength)
    {
        var n = TextMeasure.Graphemes(s);
        if (n < 1 || n > max) throw InvalidAction($"{what} must be 1 to {max} characters");
    }
}

/// <summary>
/// Picks the codec for a bound profile. fixture_json_v1 exists only for test
/// builds and test mode; with FixtureAdapterEnabled false (the production
/// default) it is refused like an unknown adapter.
/// </summary>
public sealed class GuiCodecRegistry(bool fixtureAdapterEnabled = false)
{
    public bool FixtureAdapterEnabled { get; } = fixtureAdapterEnabled;

    public IReadOnlyList<GuiAdapterId> AvailableAdapters =>
        FixtureAdapterEnabled ? [GuiAdapterId.UitarsV1, GuiAdapterId.FixtureJsonV1] : [GuiAdapterId.UitarsV1];

    public IGuiActionCodec Codec(string adapterId, string? coordinateProtocol)
    {
        var proto = CoordinateMapper.Protocol(coordinateProtocol);
        return GuiAdapterIds.FromWire(adapterId) switch
        {
            GuiAdapterId.UitarsV1 => new UITarsCodec(proto),
            GuiAdapterId.FixtureJsonV1 when FixtureAdapterEnabled => new FixtureJsonCodec(proto),
            GuiAdapterId.FixtureJsonV1 => throw new ContractError(ErrorCode.CapabilityMismatch, "fixture_json_v1 is only available in test mode"),
            _ => throw new ContractError(ErrorCode.CapabilityMismatch, "GUI adapter is not supported by this build"),
        };
    }
}

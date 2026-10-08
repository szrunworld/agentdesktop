using AgentDesktop.Contracts;
using static AgentDesktop.GUI.SuggestionRules;

namespace AgentDesktop.GUI;

/// <summary>
/// fixture_json_v1: a neutral, strictly-JSON suggestion format for tests and
/// the synthetic capability service. Only GuiCodecRegistry with
/// FixtureAdapterEnabled hands it out. One object, exactly one of
/// {"kind":"action","action":{…}}, {"kind":"wait","waitMs":N},
/// {"kind":"finish","reason":"…"}, {"kind":"needs_user","reasonCode":"…","message":"…"}.
/// </summary>
public sealed class FixtureJsonCodec(CoordinateProtocol coordinateProtocol) : IGuiActionCodec
{
    public const string AdapterVersion = "1.0.0";
    public const string PromptVersion = "fixture-prompt-1";
    public const string ParserVersion = "fixture-parser-1";

    public AdapterProvenance Provenance { get; } =
        new(GuiAdapterId.FixtureJsonV1, AdapterVersion, PromptVersion, ParserVersion, coordinateProtocol);

    public DecodedSuggestion Decode(string modelOutput, CodecContext context)
    {
        if (TextMeasure.Scalars(modelOutput) > CodecLimits.MaxReplyScalars) throw InvalidAction("reply is too long");
        JsonValue v;
        try { v = StrictJson.Parse(modelOutput); }
        catch (StrictJsonException) { throw InvalidAction("reply is not one strict JSON object"); }
        if (v.ObjectMembers is not { } members) throw InvalidAction("reply is not a JSON object");
        var keys = members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal);
        void Exactly(params string[] allowed)
        {
            if (!keys.SetEquals(allowed)) throw InvalidAction($"suggestion members must be exactly [{string.Join(", ", allowed.Order(StringComparer.Ordinal))}]");
        }
        switch (v["kind"]?.StringValue)
        {
            case "action":
                Exactly("kind", "action");
                return new DecodedSuggestion(new GuiProposalBody.Action(Action(v["action"]!, context)), null);
            case "wait":
            {
                Exactly("kind", "waitMs");
                if (v["waitMs"]?.IntValue is not { } ms) throw InvalidAction("waitMs must be an integer");
                CheckWait(ms, context.MaxWaitMs);
                return new DecodedSuggestion(new GuiProposalBody.Wait((int)ms), null);
            }
            case "finish":
            {
                Exactly("kind", "reason");
                if (v["reason"]?.StringValue is not { } r) throw InvalidAction("reason must be a string");
                CheckReason(r, "finish reason");
                return new DecodedSuggestion(new GuiProposalBody.Finish(r), null);
            }
            case "needs_user":
            {
                Exactly("kind", "reasonCode", "message");
                if (v["reasonCode"]?.StringValue is not { } code || v["message"]?.StringValue is not { } msg)
                    throw InvalidAction("reasonCode and message must be strings");
                CheckReason(code, "reasonCode", CodecLimits.MaxReasonCodeLength);
                CheckReason(msg, "needs_user message");
                return new DecodedSuggestion(new GuiProposalBody.NeedsUser(code, msg), null);
            }
            default:
                throw InvalidAction("unknown suggestion kind");
        }
    }

    private GuiAction Action(JsonValue a, CodecContext context)
    {
        // Shape first, by the contract's own GuiAction definition.
        if (ContractBundle.Shared.ValidateDomain(a, "GuiAction").Count != 0) throw InvalidAction("action does not match the contract");
        Point Source() => CoordinateMapper.SourcePixelFromModel(
            new Point(a["x"]!.DoubleValue!.Value, a["y"]!.DoubleValue!.Value), Provenance.CoordinateProtocol, context.Transform);
        switch (a["type"]?.StringValue)
        {
            case "click":
                return new GuiAction.Click(Source());
            case "type":
            {
                var text = a["text"]!.StringValue!;
                CheckType(text);
                return new GuiAction.Type(text);
            }
            case "key":
            {
                var keys = a["keys"]!.ArrayValue!.Select(k => k.StringValue).OfType<string>().ToList();
                CheckKeys(keys);
                return new GuiAction.Key(keys);
            }
            case "scroll":
                return new GuiAction.Scroll(Source(), ScrollDirections.FromWire(a["direction"]!.StringValue)!.Value,
                                            (int)a["amountPixels"]!.IntValue!.Value);
            default:
                throw InvalidAction("unknown action type");
        }
    }
}

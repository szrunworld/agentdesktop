using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using AgentDesktop.Contracts;
using static AgentDesktop.GUI.SuggestionRules;

namespace AgentDesktop.GUI;

// Port of Sources/AgentDesktopGUI/Codec/UITarsCodec.swift (itself migrated
// from 2ndscreen da5677c Sources/TarsAgent/ActionParser.swift, MIT; the
// reply format follows @ui-tars/action-parser, Apache-2.0, ByteDance).
// Strict: one call, a fixed set of actions and arguments, the profile's
// explicit coordinate protocol, refusal of anything else (spec §06.2, §08).
// Text is walked by extended grapheme clusters, as Swift does.

/// <summary>The uitars_v1 production adapter.</summary>
public sealed partial class UITarsCodec(CoordinateProtocol coordinateProtocol) : IGuiActionCodec
{
    public const string AdapterVersion = "1.0.0";
    public const string PromptVersion = "uitars-prompt-1";
    public const string ParserVersion = "uitars-parser-1";
    /// <summary>What one scroll moves, in source pixels. Part of ParserVersion.</summary>
    public const int ScrollAmountPixels = 300;

    public AdapterProvenance Provenance { get; } = new(GuiAdapterId.UitarsV1, AdapterVersion, PromptVersion, ParserVersion, coordinateProtocol);

    public DecodedSuggestion Decode(string modelOutput, CodecContext context)
    {
        if (TextMeasure.Scalars(modelOutput) > CodecLimits.MaxReplyScalars) throw InvalidAction("reply is too long");
        var (thought, callText) = Split(modelOutput);
        var call = UITarsCall.Parse(callText);
        return new DecodedSuggestion(Interpret(call, context), thought);
    }

    // ICU's (?m)^ also starts a line after \r, U+0085, U+2028 and U+2029.
    [GeneratedRegex(@"(?:\A|(?<=[\n\r\u0085  ]))[ \t]*Action[:：]")]
    private static partial Regex ActionMarker();

    [GeneratedRegex(@"^(Thought|Action_Summary)[:：]\s*")]
    private static partial Regex ThoughtPrefix();

    /// <summary>Separate the reasoning from the single Action line; none or several are refused.</summary>
    internal static (string? Thought, string Call) Split(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) throw InvalidAction("reply is empty");
        var matches = ActionMarker().Matches(trimmed);
        if (matches.Count != 1)
            throw InvalidAction(matches.Count == 0 ? "reply has no Action line" : "reply has more than one Action line");
        var m = matches[0];
        var before = trimmed[..m.Index].Trim();
        var call = trimmed[(m.Index + m.Length)..].Trim();
        return (before.Length == 0 ? null : ThoughtPrefix().Replace(before, ""), call);
    }

    private GuiProposalBody Interpret(UITarsCall call, CodecContext context)
    {
        void Only(string[] allowed, string[]? required = null)
        {
            foreach (var k in call.Arguments.Keys)
                if (!allowed.Contains(k, StringComparer.Ordinal)) throw InvalidAction($"{call.Name} does not take {k}");
            foreach (var k in required ?? [])
                if (!call.Arguments.ContainsKey(k)) throw InvalidAction($"{call.Name} needs {k}");
        }
        Point At(string key)
        {
            if (!call.Arguments.TryGetValue(key, out var value)) throw InvalidAction($"{call.Name} needs {key}");
            return CoordinateMapper.SourcePixelFromModel(UITarsCall.ParsePoint(value), Provenance.CoordinateProtocol, context.Transform);
        }

        switch (call.Name)
        {
            case "click":
                Only(["start_box"], ["start_box"]);
                return new GuiProposalBody.Action(new GuiAction.Click(At("start_box")));
            case "type":
            {
                Only(["content"], ["content"]);
                var text = call.Arguments["content"];
                CheckType(text);
                return new GuiProposalBody.Action(new GuiAction.Type(text));
            }
            case "hotkey":
            {
                Only(["key"], ["key"]);
                var keys = Keys(call.Arguments["key"]);
                CheckKeys(keys);
                return new GuiProposalBody.Action(new GuiAction.Key(keys));
            }
            case "scroll":
            {
                Only(["start_box", "direction"], ["start_box", "direction"]);
                var dir = ScrollDirections.FromWire(call.Arguments["direction"])
                    ?? throw InvalidAction("scroll direction must be up, down, left or right");
                return new GuiProposalBody.Action(new GuiAction.Scroll(At("start_box"), dir, ScrollAmountPixels));
            }
            case "wait":
                Only([]);
                // uitars wait() means one full wait of the bound profile.
                CheckWait(context.MaxWaitMs, context.MaxWaitMs);
                return new GuiProposalBody.Wait(context.MaxWaitMs);
            case "finished":
            {
                Only(["content"]);
                var reason = call.Arguments.GetValueOrDefault("content") ?? "finished";
                CheckReason(reason, "finish reason");
                return new GuiProposalBody.Finish(reason);
            }
            case "call_user":
            {
                Only(["content"]);
                var message = call.Arguments.GetValueOrDefault("content") ?? "The model asked for a person.";
                CheckReason(message, "needs_user message");
                return new GuiProposalBody.NeedsUser("model_requested_user", message);
            }
            default:
                throw InvalidAction($"action {call.Name} is not in uitars_v1");
        }
    }

    /// <summary>UI-TARS key words to contract key names; "ctrl" stays Control (the Runtime picks platform modifiers).</summary>
    internal static readonly IReadOnlyDictionary<string, string> KeyWords = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["ctrl"] = "Control", ["control"] = "Control", ["shift"] = "Shift", ["alt"] = "Alt", ["option"] = "Alt",
        ["cmd"] = "Meta", ["command"] = "Meta", ["meta"] = "Meta", ["win"] = "Meta", ["super"] = "Meta",
        ["enter"] = "Enter", ["return"] = "Enter", ["tab"] = "Tab", ["esc"] = "Escape", ["escape"] = "Escape",
        ["backspace"] = "Backspace", ["delete"] = "Delete", ["del"] = "Delete",
        ["up"] = "ArrowUp", ["down"] = "ArrowDown", ["left"] = "ArrowLeft", ["right"] = "ArrowRight",
        ["arrowup"] = "ArrowUp", ["arrowdown"] = "ArrowDown", ["arrowleft"] = "ArrowLeft", ["arrowright"] = "ArrowRight",
        ["home"] = "Home", ["end"] = "End", ["pageup"] = "PageUp", ["pagedown"] = "PageDown", ["space"] = "Space",
    };

    [GeneratedRegex("page (up|down)")]
    private static partial Regex PageWords();

    internal static IReadOnlyList<string> Keys(string text)
    {
        var words = PageWords().Replace(text.ToLowerInvariant(), "page$1")
            .Split([' ', '+'], StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) throw InvalidAction("hotkey has no keys");
        return words.Select(word =>
        {
            if (KeyWords.TryGetValue(word, out var k)) return k;
            if (TextMeasure.Graphemes(word) == 1 && word.EnumerateRunes().First().Value is >= 'a' and <= 'z' or >= '0' and <= '9')
                return word.ToUpperInvariant();
            throw InvalidAction($"hotkey key \"{word}\" is not allowed");
        }).ToList();
    }

    /// <summary>The action space for this adapter version; GuiAiProvider adds task, history and screenshot.</summary>
    public static string ActionSpace(CoordinateProtocol proto)
    {
        var coords = proto == CoordinateProtocol.Normalized1000
            ? "Coordinates are integers 0-999 on each axis of the screenshot."
            : "Coordinates are pixels of the screenshot.";
        return "Output exactly one action, in this format:\n"
            + "Thought: <one short sentence>\n"
            + "Action: <one call>\n\n"
            + "## Action Space\n"
            + "click(start_box='(x,y)')\n"
            + "type(content='text')  # \\n presses Enter at the end\n"
            + "hotkey(key='ctrl c')\n"
            + "scroll(start_box='(x,y)', direction='down or up or right or left')\n"
            + "wait()  # wait, then look again\n"
            + "finished(content='why the task is done')\n"
            + "call_user(content='what a person must do')\n\n"
            + coords;
    }
}

/// <summary>One name(key='value', …) call, parsed strictly.</summary>
internal sealed partial record UITarsCall(string Name, IReadOnlyDictionary<string, string> Arguments)
{
    public static UITarsCall Parse(string text)
    {
        var elements = Elements(text.Replace("<|box_start|>", "", StringComparison.Ordinal)
                                    .Replace("<|box_end|>", "", StringComparison.Ordinal));
        var i = 0;
        string? Peek() => i < elements.Count ? elements[i] : null;
        void SkipSpace() { while (Peek() is " " or "\t") i++; }
        string Ident()
        {
            var sb = new StringBuilder();
            while (Peek() is { Length: 1 } c && c[0] < 128 && (char.IsAsciiLetterOrDigit(c[0]) || c[0] == '_')) { sb.Append(c); i++; }
            return sb.ToString();
        }

        var name = Ident();
        if (name.Length == 0 || Peek() != "(") throw InvalidAction("action is not a call");
        i++;
        var args = new Dictionary<string, string>(StringComparer.Ordinal);
        SkipSpace();
        if (Peek() == ")")
        {
            i++;
        }
        else
        {
            while (true)
            {
                SkipSpace();
                var key = Ident();
                if (key == "point") key = "start_box";
                if (key.Length == 0) throw InvalidAction($"bad argument in {name}");
                SkipSpace();
                if (Peek() != "=") throw InvalidAction($"argument {key} has no value");
                i++;
                SkipSpace();
                var q = Peek();
                if (q is not ("'" or "\"")) throw InvalidAction($"argument {key} must be quoted");
                i++;
                var value = new StringBuilder();
                var closed = false;
                while (Peek() is { } c)
                {
                    i++;
                    if (c == q) { closed = true; break; }
                    if (c == "\\")
                    {
                        if (Peek() is not { } e) break;
                        i++;
                        value.Append(e switch
                        {
                            "n" => "\n", "t" => "\t", "\\" => "\\", "'" => "'", "\"" => "\"",
                            _ => throw InvalidAction($"bad escape in {key}"),
                        });
                        continue;
                    }
                    if (c is "\n" or "\r") throw InvalidAction($"line break inside {key}");
                    value.Append(c);
                }
                if (!closed) throw InvalidAction($"unterminated value for {key}");
                if (!args.TryAdd(key, value.ToString())) throw InvalidAction($"argument {key} appears twice");
                SkipSpace();
                if (Peek() == ",") { i++; continue; }
                if (Peek() == ")") { i++; break; }
                throw InvalidAction($"expected , or ) in {name}");
            }
        }
        if (string.Concat(elements.Skip(i)).Trim().Length != 0)
            throw InvalidAction("text after the action; exactly one action is allowed");
        return new UITarsCall(name, args);
    }

    private static List<string> Elements(string s)
    {
        var list = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(s);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }

    [GeneratedRegex(@"^\d+(\.\d+)?$")]
    private static partial Regex Decimal();

    [GeneratedRegex(@"^[-+]?(\d+(\.\d+)?|inf|nan)$", RegexOptions.IgnoreCase)]
    private static partial Regex NumberLike();

    private static string TrimSpaces(string s)
    {
        static bool Space(char c) => c == '\t' || char.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;
        int a = 0, b = s.Length;
        while (a < b && Space(s[a])) a++;
        while (b > a && Space(s[b - 1])) b--;
        return s[a..b];
    }

    /// <summary>A point in the model's own units: (x,y), [x,y], [x y], &lt;point&gt;x y&lt;/point&gt;, or a box whose centre is taken.</summary>
    public static Point ParsePoint(string value)
    {
        var v = TrimSpaces(value);
        foreach (var (open, close) in new[] { ("<point>", "</point>"), ("<bbox>", "</bbox>") })
        {
            if (!v.StartsWith(open, StringComparison.Ordinal)) continue;
            if (!v.EndsWith(close, StringComparison.Ordinal)) throw InvalidAction($"unterminated {open}");
            v = v[open.Length..^close.Length];
        }
        if (v.Length > 0 && v[0] is '(' or '[')
        {
            var f = v[0];
            var l = v[^1];
            if (!((f == '(' && l == ')') || (f == '[' && l == ']'))) throw InvalidAction("unbalanced point");
            v = v[1..^1];
        }
        var parts = v.Split([',', ' '], StringSplitOptions.RemoveEmptyEntries);
        var numbers = parts
            .Select(p => Decimal().IsMatch(p) && double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : (double?)null)
            .Where(d => d is not null).Select(d => d!.Value).ToList();
        if (numbers.Count != parts.Length)
        {
            // A negative or non-finite number lies outside the domain; anything else is no coordinate at all.
            if (parts.All(p => NumberLike().IsMatch(p)))
                throw new ContractError(ErrorCode.CoordinateOutOfBounds, "point is outside the model canvas");
            throw InvalidAction("point is not a list of numbers");
        }
        return numbers.Count switch
        {
            2 => new Point(numbers[0], numbers[1]),
            4 when numbers[2] >= numbers[0] && numbers[3] >= numbers[1] =>
                new Point((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2),
            4 => throw InvalidAction("box corners are reversed"),
            _ => throw InvalidAction("a point has 2 numbers and a box 4"),
        };
    }
}

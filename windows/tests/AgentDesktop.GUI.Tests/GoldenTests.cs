using AgentDesktop.Contracts;
using Xunit;

namespace AgentDesktop.GUI.Tests;

// The codec and coordinate golden shared with Swift
// (Tests/AgentDesktopGUITests/Fixtures/codec-golden.json, written by
// CodecGoldenExportTests.swift). Each case is recomputed here with the C#
// implementation and compared: numbers within the tolerance, the rest exactly.

internal static class Golden
{
    public static readonly string RepoRoot = FindRoot();

    private static string FindRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "contracts", "ai-gui", "v1", "rpc.schema.json")))
            dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repository root not found");
    }

    public static readonly JsonValue File_ = StrictJson.Parse(File.ReadAllBytes(
        Path.Combine(RepoRoot, "Tests", "AgentDesktopGUITests", "Fixtures", "codec-golden.json")));

    public static double Tolerance => File_["tolerance"]!.DoubleValue!.Value;

    public static JsonValue Num(double v) =>
        double.IsNaN(v) ? JsonValue.String("NaN") : double.IsPositiveInfinity(v) ? JsonValue.String("Infinity")
        : double.IsNegativeInfinity(v) ? JsonValue.String("-Infinity") : JsonValue.Double(v);

    public static double Dbl(JsonValue? v) => v?.StringValue switch
    {
        "NaN" => double.NaN,
        "Infinity" => double.PositiveInfinity,
        "-Infinity" => double.NegativeInfinity,
        _ => v?.DoubleValue ?? double.NaN,
    };

    public static double[] Nums(JsonValue? v) => v?.ArrayValue?.Select(Dbl).ToArray() ?? [];
    public static JsonValue Pt(Point p) => JsonValue.Array([Num(p.X), Num(p.Y)]);
    public static Point Pt(JsonValue? v) { var n = Nums(v); return new Point(n[0], n[1]); }
    public static Size Sz(JsonValue? v) { var n = Nums(v); return new Size(n[0], n[1]); }
    public static JsonValue Sz(Size s) => JsonValue.Array([Num(s.Width), Num(s.Height)]);
    public static GuiAffineTransform Affine(JsonValue? v) { var n = Nums(v); return new GuiAffineTransform(n[0], n[1], n[2], n[3], n[4], n[5]); }
    public static JsonValue Affine(GuiAffineTransform t) => JsonValue.Array(t.Array.Select(Num));

    public static ScreenshotTransform Pipeline(JsonValue v)
    {
        Rect? crop = v["crop"] is { } c ? new Rect(Nums(c)[0], Nums(c)[1], Nums(c)[2], Nums(c)[3]) : null;
        Insets? insets = v["letterbox"] is { } l ? new Insets(Nums(l)[0], Nums(l)[1], Nums(l)[2], Nums(l)[3]) : null;
        Size? resized = v["resized"] is { } r ? Sz(r) : null;
        return ScreenshotTransform.Pipeline(Sz(v["sourceSize"]), crop, resized, insets);
    }

    public static JsonValue Outcome(Func<JsonValue> body)
    {
        try { return JsonValue.Obj(("ok", body())); }
        catch (ContractError e) { return JsonValue.Obj(("code", JsonValue.String(e.Code.Wire()))); }
        catch (Exception) { return JsonValue.Obj(("code", JsonValue.String("INTERNAL_ERROR"))); }
    }

    /// <summary>Structural comparison, numbers within the tolerance; null when equal, else where they differ.</summary>
    public static string? Same(JsonValue a, JsonValue b, string path = "")
    {
        if (a.Kind == JsonKind.Number && b.Kind == JsonKind.Number)
            return Math.Abs(a.DoubleValue!.Value - b.DoubleValue!.Value) <= Tolerance ? null : $"{path}: {a} != {b}";
        if (a.Kind == JsonKind.Array && b.Kind == JsonKind.Array)
        {
            if (a.ArrayValue!.Count != b.ArrayValue!.Count) return $"{path}: {a.ArrayValue.Count} items != {b.ArrayValue.Count}";
            for (var i = 0; i < a.ArrayValue.Count; i++)
                if (Same(a.ArrayValue[i], b.ArrayValue[i], $"{path}/{i}") is { } d) return d;
            return null;
        }
        if (a.Kind == JsonKind.Object && b.Kind == JsonKind.Object)
        {
            var ak = a.ObjectMembers!.Select(m => m.Key).Order(StringComparer.Ordinal).ToList();
            var bk = b.ObjectMembers!.Select(m => m.Key).Order(StringComparer.Ordinal).ToList();
            if (!ak.SequenceEqual(bk)) return $"{path}: keys [{string.Join(",", ak)}] != [{string.Join(",", bk)}]";
            foreach (var m in a.ObjectMembers!)
                if (Same(m.Value, b[m.Key]!, $"{path}/{m.Key}") is { } d) return d;
            return null;
        }
        return a.Equals(b) ? null : $"{path}: {a} != {b}";
    }

    // MARK: evaluation, step for step with GoldenEval in the Swift test

    public static JsonValue Coordinate(JsonValue c) => Outcome(() =>
    {
        switch (c["op"]?.StringValue)
        {
            case "pipeline":
            {
                var t = Pipeline(c["pipeline"]!);
                return JsonValue.Obj(("modelInputSize", Sz(t.ModelInputSize)), ("modelToSource", Affine(t.ModelToSource)),
                                     ("sourceToModel", Affine(t.SourceToModel)));
            }
            case "sourceFromModel":
            {
                var t = Pipeline(c["pipeline"]!);
                var proto = CoordinateMapper.Protocol(c["protocol"]?.StringValue);
                return Pt(CoordinateMapper.SourcePixelFromModel(Pt(c["point"]), proto, t));
            }
            case "modelCanvas":
                return Pt(CoordinateMapper.ModelCanvasPoint(Pt(c["point"]), CoordinateMapper.Protocol(c["protocol"]?.StringValue), Sz(c["canvas"])));
            case "applyModelToSource":
                return Pt(Pipeline(c["pipeline"]!).ModelToSource.Apply(Pt(c["point"])));
            case "desktopFromSource":
                return Pt(CoordinateMapper.DesktopPoint(Pt(c["point"]), Sz(c["sourceSize"]), Affine(c["sourceToDesktop"])));
            case "checkDomain":
                CoordinateMapper.CheckDomain(Pt(c["point"]), Sz(c["size"]), "point");
                return JsonValue.Bool(true);
            case "coordinateProtocol":
                return JsonValue.String(CoordinateMapper.Protocol(c["protocolName"]?.StringValue).Wire());
            case "affineFromArray":
                return Affine(GuiAffineTransform.FromArray(Nums(c["array"])));
            case "invert":
                return Affine(Affine(c["affine"]).Inverted());
            case "apply":
                return Pt(Affine(c["affine"]).Apply(Pt(c["point"])));
            case "then":
                return Affine(Affine(c["first"]).Then(Affine(c["next"])));
            case "explicitTransform":
            {
                var s = Sz(c["sourceSize"]);
                var t = new ScreenshotTransform(s, new Rect(new Point(0, 0), s), s, Insets.Zero, s,
                                                Affine(c["sourceToModel"]), Affine(c["modelToSource"]));
                return Affine(t.ModelToSource);
            }
            default:
                throw new ContractError(ErrorCode.InternalError, "unknown op");
        }
    });

    public static CodecContext Context(JsonValue c)
    {
        var b = File_["codec"]!["context"]!;
        return new CodecContext(Pipeline(c["pipeline"] ?? b["pipeline"]!), (int)(c["maxWaitMs"]?.IntValue ?? b["maxWaitMs"]!.IntValue!.Value));
    }

    public static IGuiActionCodec Codec(JsonValue c) =>
        new GuiCodecRegistry(fixtureAdapterEnabled: true).Codec(c["adapterId"]!.StringValue!, c["protocol"]!.StringValue!);

    public static JsonValue Suggestion(JsonValue c) =>
        Outcome(() => Codec(c).Decode(c["reply"]!.StringValue!, Context(c)).Body.Json);

    public static JsonValue Registry(JsonValue c) => Outcome(() =>
        new GuiCodecRegistry(c["fixtureEnabled"]?.BoolValue ?? false)
            .Codec(c["adapterId"]!.StringValue!, c["protocol"]?.StringValue).Provenance.Json);

    public static Observation Observation(JsonValue o)
    {
        var s = o["stamp"]!;
        var stamp = new ObservationStamp(s["sessionId"]!.StringValue!, s["desktopId"]!.StringValue!, s["snapshotId"]!.StringValue!,
                                         s["bindingEpoch"]!.IntValue!.Value, s["runGeneration"]!.IntValue!.Value);
        var target = new TargetIdentity("com.agentdesktop.neutral-form", 4242, "ps-1", "w-1", 3, "golden", new Rect(-1440, 120, 800, 500));
        var shots = o["screenshots"]!.ArrayValue!.Select(sh => new ScreenshotDescriptor(
            sh["screenshotId"]!.StringValue!, "art", new string('a', 64), "image/png", "t1",
            Affine(sh["sourceToDesktop"]), Pipeline(sh["pipeline"]!))).ToList();
        return new Observation(o["observationId"]!.StringValue!, stamp, target,
                               DateTimeOffset.FromUnixTimeSeconds(1_791_000_000), shots);
    }

    public static JsonValue Proposal(JsonValue c) => Outcome(() =>
    {
        var obs = Observation(File_["proposals"]!["observation"]!);
        var (p, _) = new ProposalFactory(() => "prop-golden-1").Propose(
            Codec(c), c["reply"]!.StringValue!, c["runId"]!.StringValue!, (int)c["stepIndex"]!.IntValue!.Value,
            c["inferenceAttemptId"]!.StringValue!, obs, c["screenshotId"]!.StringValue!, (int)c["maxWaitMs"]!.IntValue!.Value);
        var m = new List<(string, JsonValue)> { ("proposal", p.Json) };
        if (p.Body is GuiProposalBody.Action { Value: GuiAction.Type }) m.Add(("redactedBody", JsonValue.String(p.Body.RedactedDescription)));
        if (p.Body is GuiProposalBody.Action { Value: GuiAction.Click click } && obs.Screenshot(p.ScreenshotId) is { } shot)
            m.Add(("desktopPoint", Pt(CoordinateMapper.DesktopPoint(click.SourcePixel, shot))));
        return JsonValue.Obj([.. m]);
    });

    public static JsonValue AffineExpect(JsonValue prop) => Outcome(() =>
    {
        var composed = Affine(prop["first"]).Then(Affine(prop["next"]));
        var inverse = composed.Inverted();
        var rows = prop["points"]!.ArrayValue!.Select(pv =>
        {
            var once = composed.Apply(Pt(pv));
            return JsonValue.Obj(("composed", Pt(once)), ("back", Pt(inverse.Apply(once))));
        });
        return JsonValue.Obj(("composed", Affine(composed)), ("inverse", Affine(inverse)), ("points", JsonValue.Array(rows)));
    });

    public static string Name(JsonValue c) =>
        c["name"]?.StringValue ?? c["reply"]?.StringValue ?? $"{c["adapterId"]?.StringValue} {c["protocol"]?.StringValue}";
}

public class GoldenTests
{
    private static void AllMatch(IEnumerable<JsonValue> cases, Func<JsonValue, JsonValue> eval, int atLeast)
    {
        var list = cases.ToList();
        Assert.True(list.Count >= atLeast, $"only {list.Count} cases");
        var failures = list.Select(c => (c, d: Golden.Same(eval(c), c["expect"]!)))
            .Where(x => x.d is not null).Select(x => $"{Golden.Name(x.c)} → {x.d}").ToList();
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    // COO-001..008: transforms, domains, protocols, inverses.
    [Fact]
    public void Coordinates() => AllMatch(Golden.File_["coordinates"]!.ArrayValue!, Golden.Coordinate, 30);

    // COO-007: 100 fixed points; composition and inverse agree with Swift and with stepwise application.
    [Fact]
    public void AffineProperty()
    {
        var prop = Golden.File_["affineProperty"]!;
        Assert.Null(Golden.Same(Golden.AffineExpect(prop), prop["expect"]!));
        var t1 = Golden.Affine(prop["first"]);
        var t2 = Golden.Affine(prop["next"]);
        var composed = t1.Then(t2);
        var inverse = composed.Inverted();
        var worst = 0.0;
        var points = prop["points"]!.ArrayValue!;
        Assert.Equal(100, points.Count);
        foreach (var pv in points)
        {
            var p = Golden.Pt(pv);
            var step = t2.Apply(t1.Apply(p));
            var once = composed.Apply(p);
            var back = inverse.Apply(once);
            worst = new[] { worst, Math.Abs(step.X - once.X), Math.Abs(step.Y - once.Y), Math.Abs(back.X - p.X), Math.Abs(back.Y - p.Y) }.Max();
        }
        Assert.True(worst <= Golden.Tolerance, $"max error {worst}");
    }

    // GUI-001/002: UI-TARS and fixture_json suggestions and refusals.
    [Fact]
    public void Suggestions() => AllMatch(Golden.File_["codec"]!["suggestions"]!.ArrayValue!, Golden.Suggestion, 90);

    [Fact]
    public void Registry() => AllMatch(Golden.File_["registry"]!.ArrayValue!, Golden.Registry, 7);

    // GUI-004 and proposal encoding: identity from the observation, wire JSON, redaction.
    [Fact]
    public void Proposals() => AllMatch(Golden.File_["proposals"]!["cases"]!.ArrayValue!, Golden.Proposal, 10);
}

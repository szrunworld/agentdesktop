using System.Globalization;
using AgentDesktop.Contracts;

namespace AgentDesktop.GUI;

// Observation types of contract v1 (spec §04, §08.3), mirroring
// Sources/AgentDesktopContracts/Domain/GuiObservation.swift.

public sealed record TargetIdentity(string AppId, long ProcessId, string ProcessStartId, string WindowId,
                                    long WindowGeometryRevision, string BackendId, Rect WindowFrameDesktopLogical)
{
    public JsonValue Json
    {
        get
        {
            var f = WindowFrameDesktopLogical;
            return JsonValue.Obj(
                ("appId", JsonValue.String(AppId)), ("processId", JsonValue.Int(ProcessId)),
                ("processStartId", JsonValue.String(ProcessStartId)), ("windowId", JsonValue.String(WindowId)),
                ("windowGeometryRevision", JsonValue.Int(WindowGeometryRevision)), ("backendId", JsonValue.String(BackendId)),
                ("windowFrameDesktopLogical", JsonValue.Obj(
                    ("x", JsonValue.Double(f.Origin.X)), ("y", JsonValue.Double(f.Origin.Y)),
                    ("width", JsonValue.Double(f.Size.Width)), ("height", JsonValue.Double(f.Size.Height)))));
        }
    }
}

/// <summary>Source screenshot → model input canvas: crop, resize, then letterbox padding.</summary>
public sealed record ScreenshotTransform
{
    public Size SourceSize { get; }
    public Rect Crop { get; }
    public Size ResizedSize { get; }
    public Insets Letterbox { get; }
    public Size ModelInputSize { get; }
    public GuiAffineTransform SourceToModel { get; }
    public GuiAffineTransform ModelToSource { get; }

    /// <summary>Builds and checks a transform: finite, invertible, each map the other's inverse, sizes consistent.</summary>
    public ScreenshotTransform(Size sourceSize, Rect crop, Size resizedSize, Insets letterbox, Size modelInputSize,
                               GuiAffineTransform sourceToModel, GuiAffineTransform modelToSource)
    {
        SourceSize = sourceSize; Crop = crop; ResizedSize = resizedSize; Letterbox = letterbox;
        ModelInputSize = modelInputSize; SourceToModel = sourceToModel; ModelToSource = modelToSource;
        Validate();
    }

    public static ScreenshotTransform Pipeline(Size sourceSize, Rect? crop = null, Size? resizedSize = null, Insets? letterbox = null)
    {
        var c = crop ?? new Rect(new Point(0, 0), sourceSize);
        var resized = resizedSize ?? c.Size;
        var l = letterbox ?? Insets.Zero;
        var toModel = GuiAffineTransform.Translate(-c.Origin.X, -c.Origin.Y)
            .Then(GuiAffineTransform.Scale(resized.Width / c.Size.Width, resized.Height / c.Size.Height))
            .Then(GuiAffineTransform.Translate(l.Left, l.Top));
        var model = new Size(resized.Width + l.Left + l.Right, resized.Height + l.Top + l.Bottom);
        return new ScreenshotTransform(sourceSize, c, resized, l, model, toModel, toModel.Inverted());
    }

    private void Validate()
    {
        static ContractError Bad(string m) => new(ErrorCode.ValidationError, $"screenshot transform: {m}");
        double[] dims = [SourceSize.Width, SourceSize.Height, Crop.Size.Width, Crop.Size.Height,
                         ResizedSize.Width, ResizedSize.Height, ModelInputSize.Width, ModelInputSize.Height];
        if (!dims.All(d => double.IsFinite(d) && d > 0)) throw Bad("sizes must be positive");
        if (!(Crop.Origin.X >= 0 && Crop.Origin.Y >= 0
              && Crop.Origin.X + Crop.Size.Width <= SourceSize.Width
              && Crop.Origin.Y + Crop.Size.Height <= SourceSize.Height)) throw Bad("crop lies outside the source");
        double[] insets = [Letterbox.Left, Letterbox.Top, Letterbox.Right, Letterbox.Bottom];
        if (!insets.All(d => double.IsFinite(d) && d >= 0)) throw Bad("letterbox must be non-negative");
        if (!(Math.Abs(ResizedSize.Width + Letterbox.Left + Letterbox.Right - ModelInputSize.Width) < 1e-9
              && Math.Abs(ResizedSize.Height + Letterbox.Top + Letterbox.Bottom - ModelInputSize.Height) < 1e-9))
            throw Bad("model input size is not resized size plus letterbox");
        var inverse = SourceToModel.Inverted();
        _ = ModelToSource.Inverted();
        if (!inverse.IsClose(ModelToSource, 1e-9)) throw Bad("modelToSource is not the inverse of sourceToModel");
    }

    /// <summary>The part of the model canvas that shows the image (letterbox excluded).</summary>
    public Rect ContentRegion => new(Letterbox.Left, Letterbox.Top, ResizedSize.Width, ResizedSize.Height);

    public JsonValue Json
    {
        get
        {
            static JsonValue S(Size s) => JsonValue.Obj(("width", JsonValue.Double(s.Width)), ("height", JsonValue.Double(s.Height)));
            return JsonValue.Obj(
                ("sourceSize", S(SourceSize)),
                ("crop", JsonValue.Obj(("x", JsonValue.Double(Crop.Origin.X)), ("y", JsonValue.Double(Crop.Origin.Y)),
                                       ("width", JsonValue.Double(Crop.Size.Width)), ("height", JsonValue.Double(Crop.Size.Height)))),
                ("resizedSize", S(ResizedSize)),
                ("letterbox", JsonValue.Obj(("left", JsonValue.Double(Letterbox.Left)), ("top", JsonValue.Double(Letterbox.Top)),
                                            ("right", JsonValue.Double(Letterbox.Right)), ("bottom", JsonValue.Double(Letterbox.Bottom)))),
                ("modelInputSize", S(ModelInputSize)),
                ("sourceToModel", SourceToModel.Json),
                ("modelToSource", ModelToSource.Json));
        }
    }

    public static ScreenshotTransform FromJson(JsonValue json)
    {
        static Size S(JsonValue? v) => v?["width"]?.DoubleValue is { } w && v["height"]?.DoubleValue is { } h
            ? new Size(w, h) : throw new ContractError(ErrorCode.ValidationError, "screenshot transform: bad size");
        var c = json["crop"];
        var l = json["letterbox"];
        if (c?["x"]?.DoubleValue is not { } x || c["y"]?.DoubleValue is not { } y || c["width"]?.DoubleValue is not { } w
            || c["height"]?.DoubleValue is not { } h || l?["left"]?.DoubleValue is not { } ll || l["top"]?.DoubleValue is not { } lt
            || l["right"]?.DoubleValue is not { } lr || l["bottom"]?.DoubleValue is not { } lb
            || json["sourceToModel"] is not { } s2m || json["modelToSource"] is not { } m2s)
            throw new ContractError(ErrorCode.ValidationError, "screenshot transform is incomplete");
        return new ScreenshotTransform(S(json["sourceSize"]), new Rect(x, y, w, h), S(json["resizedSize"]),
            new Insets(ll, lt, lr, lb), S(json["modelInputSize"]), GuiAffineTransform.FromJson(s2m), GuiAffineTransform.FromJson(m2s));
    }
}

public sealed record ScreenshotDescriptor
{
    public string ScreenshotId { get; }
    public string ArtifactRef { get; }
    public string Sha256 { get; }
    public string MimeType { get; }
    public string TransformVersion { get; }
    /// <summary>Source screenshot pixels → Desktop logical points (negative origins are legal).</summary>
    public GuiAffineTransform SourceToDesktop { get; }
    public ScreenshotTransform Transform { get; }

    public ScreenshotDescriptor(string screenshotId, string artifactRef, string sha256, string mimeType,
                                string transformVersion, GuiAffineTransform sourceToDesktop, ScreenshotTransform transform)
    {
        ScreenshotId = screenshotId; ArtifactRef = artifactRef; Sha256 = sha256; MimeType = mimeType;
        TransformVersion = transformVersion; SourceToDesktop = sourceToDesktop; Transform = transform;
        _ = sourceToDesktop.Inverted();
    }

    public JsonValue Json => JsonValue.Obj(
        ("screenshotId", JsonValue.String(ScreenshotId)), ("artifactRef", JsonValue.String(ArtifactRef)),
        ("sha256", JsonValue.String(Sha256)), ("mimeType", JsonValue.String(MimeType)),
        ("transformVersion", JsonValue.String(TransformVersion)),
        ("sourceToDesktop", SourceToDesktop.Json), ("transform", Transform.Json));
}

public sealed record ObservationStamp(string SessionId, string DesktopId, string SnapshotId, long BindingEpoch, long RunGeneration);

public sealed record Observation(string ObservationId, ObservationStamp Stamp, TargetIdentity Target,
                                 DateTimeOffset ObservedAt, IReadOnlyList<ScreenshotDescriptor> Screenshots)
{
    public ScreenshotDescriptor? Screenshot(string id) => Screenshots.FirstOrDefault(s => s.ScreenshotId == id);

    public JsonValue Json => JsonValue.Obj(
        ("observationId", JsonValue.String(ObservationId)), ("snapshotId", JsonValue.String(Stamp.SnapshotId)),
        ("sessionId", JsonValue.String(Stamp.SessionId)), ("desktopId", JsonValue.String(Stamp.DesktopId)),
        ("target", Target.Json), ("bindingEpoch", JsonValue.Int(Stamp.BindingEpoch)),
        ("runGeneration", JsonValue.Int(Stamp.RunGeneration)),
        ("observedAt", JsonValue.String(ObservedAt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture))),
        ("screenshots", JsonValue.Array(Screenshots.Select(s => s.Json))));
}

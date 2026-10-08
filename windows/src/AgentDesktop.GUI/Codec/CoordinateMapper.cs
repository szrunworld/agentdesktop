using AgentDesktop.Contracts;

namespace AgentDesktop.GUI;

/// <summary>
/// Spec §08: model coordinates → model canvas pixels → source screenshot
/// pixels → Desktop logical points. Every step checks its domain
/// [0,width) × [0,height); nothing is ever clamped.
/// </summary>
public static class CoordinateMapper
{
    private static ContractError OutOfBounds(string what, Point p) =>
        new(ErrorCode.CoordinateOutOfBounds, $"{what} {p} is outside its domain");

    /// <summary>A model-written coordinate on the model canvas, by the profile's explicit protocol.</summary>
    public static Point ModelCanvasPoint(Point raw, CoordinateProtocol proto, Size canvas)
    {
        if (!raw.IsFinite) throw new ContractError(ErrorCode.CoordinateOutOfBounds, "coordinate is not finite");
        if (proto == CoordinateProtocol.Normalized1000)
        {
            if (!(raw.X >= 0 && raw.X < 1000 && raw.Y >= 0 && raw.Y < 1000)) throw OutOfBounds("normalized coordinate", raw);
            var p = new Point(raw.X / 1000 * canvas.Width, raw.Y / 1000 * canvas.Height);
            CheckDomain(p, canvas, "model canvas point");
            return p;
        }
        CheckDomain(raw, canvas, "model canvas point");
        return raw;
    }

    /// <summary>Parse a protocol name strictly: missing or unknown is VALIDATION_ERROR.</summary>
    public static CoordinateProtocol Protocol(string? name) =>
        CoordinateProtocols.FromWire(name)
        ?? throw new ContractError(ErrorCode.ValidationError, "coordinateProtocol must be normalized_1000 or image_pixels");

    public static void CheckDomain(Point p, Size size, string what)
    {
        if (!(p.IsFinite && p.X >= 0 && p.Y >= 0 && p.X < size.Width && p.Y < size.Height)) throw OutOfBounds(what, p);
    }

    /// <summary>A model canvas point to source pixels; letterbox points and points outside the source are refused.</summary>
    public static Point SourcePixelFromModelCanvas(Point p, ScreenshotTransform t)
    {
        CheckDomain(p, t.ModelInputSize, "model canvas point");
        var c = t.ContentRegion;
        if (!(p.X >= c.Origin.X && p.Y >= c.Origin.Y && p.X < c.Origin.X + c.Size.Width && p.Y < c.Origin.Y + c.Size.Height))
            throw OutOfBounds("letterbox point", p);
        var s = t.ModelToSource.Apply(p);
        CheckDomain(s, t.SourceSize, "source pixel");
        return s;
    }

    /// <summary>The whole model-side chain for one coordinate the model wrote.</summary>
    public static Point SourcePixelFromModel(Point raw, CoordinateProtocol proto, ScreenshotTransform t) =>
        SourcePixelFromModelCanvas(ModelCanvasPoint(raw, proto, t.ModelInputSize), t);

    /// <summary>Source pixels to Desktop logical points; the result may be negative and is not rescaled again.</summary>
    public static Point DesktopPoint(Point p, Size sourceSize, GuiAffineTransform sourceToDesktop)
    {
        CheckDomain(p, sourceSize, "source pixel");
        _ = sourceToDesktop.Inverted();
        var d = sourceToDesktop.Apply(p);
        if (!d.IsFinite) throw OutOfBounds("desktop point", d);
        return d;
    }

    public static Point DesktopPoint(Point p, ScreenshotDescriptor shot) =>
        DesktopPoint(p, shot.Transform.SourceSize, shot.SourceToDesktop);
}

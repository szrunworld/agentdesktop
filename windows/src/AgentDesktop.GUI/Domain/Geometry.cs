using System.Globalization;
using AgentDesktop.Contracts;

namespace AgentDesktop.GUI;

// GUI geometry of contract v1 (spec §08), mirroring
// Sources/AgentDesktopContracts/Domain/GuiGeometry.swift.

public readonly record struct Point(double X, double Y)
{
    public bool IsFinite => double.IsFinite(X) && double.IsFinite(Y);
    public override string ToString() =>
        string.Create(CultureInfo.InvariantCulture, $"({X}, {Y})");
}

public readonly record struct Size(double Width, double Height);

public readonly record struct Rect(Point Origin, Size Size)
{
    public Rect(double x, double y, double width, double height) : this(new Point(x, y), new Size(width, height)) { }
}

public readonly record struct Insets(double Left, double Top, double Right, double Bottom)
{
    public static readonly Insets Zero = new(0, 0, 0, 0);
}

/// <summary>How a GUI adapter's model writes coordinates; never inferred from magnitudes.</summary>
public enum CoordinateProtocol { Normalized1000, ImagePixels }

public static class CoordinateProtocols
{
    public static string Wire(this CoordinateProtocol p) => p switch
    {
        CoordinateProtocol.Normalized1000 => "normalized_1000",
        _ => "image_pixels",
    };

    public static CoordinateProtocol? FromWire(string? s) => s switch
    {
        "normalized_1000" => CoordinateProtocol.Normalized1000,
        "image_pixels" => CoordinateProtocol.ImagePixels,
        _ => null,
    };
}

/// <summary><c>[a,b,c,d,tx,ty]</c>: x' = a*x + c*y + tx, y' = b*x + d*y + ty.</summary>
public readonly record struct GuiAffineTransform(double A, double B, double C, double D, double Tx, double Ty)
{
    public static readonly GuiAffineTransform Identity = new(1, 0, 0, 1, 0, 0);

    public static GuiAffineTransform Scale(double sx, double sy) => new(sx, 0, 0, sy, 0, 0);
    public static GuiAffineTransform Translate(double tx, double ty) => new(1, 0, 0, 1, tx, ty);

    /// <summary>From the wire array; must hold exactly six finite numbers.</summary>
    public static GuiAffineTransform FromArray(IReadOnlyList<double> v)
    {
        if (v.Count != 6) throw new ContractError(ErrorCode.ValidationError, "an affine transform has exactly six numbers");
        var t = new GuiAffineTransform(v[0], v[1], v[2], v[3], v[4], v[5]);
        if (!t.IsFinite) throw new ContractError(ErrorCode.ValidationError, "affine transform is not finite");
        return t;
    }

    public static GuiAffineTransform FromJson(JsonValue? json)
    {
        if (json?.ArrayValue is not { } items) throw new ContractError(ErrorCode.ValidationError, "affine transform must be an array");
        var numbers = items.Select(i => i.DoubleValue).ToList();
        if (numbers.Any(n => n is null)) throw new ContractError(ErrorCode.ValidationError, "affine transform must hold numbers");
        return FromArray(numbers.Select(n => n!.Value).ToList());
    }

    public double[] Array => [A, B, C, D, Tx, Ty];
    public JsonValue Json => JsonValue.Array(Array.Select(JsonValue.Double));
    public bool IsFinite => Array.All(double.IsFinite);
    public double Determinant => A * D - B * C;

    public Point Apply(Point p) => new(A * p.X + C * p.Y + Tx, B * p.X + D * p.Y + Ty);

    /// <summary><c>this</c> first, then <paramref name="next"/>.</summary>
    public GuiAffineTransform Then(GuiAffineTransform next) => new(
        next.A * A + next.C * B,
        next.B * A + next.D * B,
        next.A * C + next.C * D,
        next.B * C + next.D * D,
        next.A * Tx + next.C * Ty + next.Tx,
        next.B * Tx + next.D * Ty + next.Ty);

    /// <summary>The inverse; VALIDATION_ERROR for a singular or non-finite matrix.</summary>
    public GuiAffineTransform Inverted()
    {
        var det = Determinant;
        if (!IsFinite || !double.IsFinite(det) || Math.Abs(det) <= 1e-12)
            throw new ContractError(ErrorCode.ValidationError, $"affine transform {this} is singular");
        double ia = D / det, ib = -B / det, ic = -C / det, id = A / det;
        return new GuiAffineTransform(ia, ib, ic, id, -(ia * Tx + ic * Ty), -(ib * Tx + id * Ty));
    }

    public bool IsClose(GuiAffineTransform other, double tolerance = 1e-9) =>
        Array.Zip(other.Array).All(p => Math.Abs(p.First - p.Second)
            <= tolerance * Math.Max(1, Math.Max(Math.Abs(p.First), Math.Abs(p.Second))));

    public override string ToString() =>
        "[" + string.Join(",", Array.Select(v => v.ToString("R", CultureInfo.InvariantCulture))) + "]";
}

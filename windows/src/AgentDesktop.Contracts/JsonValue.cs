using System.Globalization;
using System.Text;

namespace AgentDesktop.Contracts;

public enum JsonKind { Null, Bool, Number, String, Array, Object }

/// <summary>
/// A JSON value as received on the wire, object members kept in their
/// original order. Produced by <see cref="StrictJson.Parse(byte[], int)"/>,
/// which refuses duplicate keys, so an object never holds a key twice.
/// Mirrors Swift's JSONValue.
/// </summary>
public sealed class JsonValue : IEquatable<JsonValue>
{
    public JsonKind Kind { get; }
    private readonly bool _bool;
    private readonly string? _raw;      // number as written, or string value
    private readonly double _number;
    private readonly IReadOnlyList<JsonValue>? _array;
    private readonly IReadOnlyList<KeyValuePair<string, JsonValue>>? _object;

    private JsonValue(JsonKind kind, bool b = false, string? raw = null, double number = 0,
                      IReadOnlyList<JsonValue>? array = null, IReadOnlyList<KeyValuePair<string, JsonValue>>? obj = null)
    {
        Kind = kind;
        _bool = b;
        _raw = raw;
        _number = number;
        _array = array;
        _object = obj;
    }

    public static readonly JsonValue Null = new(JsonKind.Null);
    public static JsonValue Bool(bool b) => new(JsonKind.Bool, b: b);
    public static JsonValue Number(string raw, double value) => new(JsonKind.Number, raw: raw, number: value);
    public static JsonValue String(string s) => new(JsonKind.String, raw: s);
    public static JsonValue Array(IEnumerable<JsonValue> items) => new(JsonKind.Array, array: items.ToList());
    public static JsonValue Object(IEnumerable<KeyValuePair<string, JsonValue>> members)
    {
        var list = members.ToList();
        if (list.Select(m => m.Key).Distinct(StringComparer.Ordinal).Count() != list.Count)
            throw new ArgumentException("duplicate key in object");
        return new JsonValue(JsonKind.Object, obj: list);
    }
    public static JsonValue Obj(params (string Key, JsonValue Value)[] members) =>
        Object(members.Select(m => new KeyValuePair<string, JsonValue>(m.Key, m.Value)));
    public static JsonValue Int(long v) => Number(v.ToString(CultureInfo.InvariantCulture), v);
    public static JsonValue Double(double v)
    {
        if (v == Math.Round(v) && Math.Abs(v) < 9.007199254740992e15)
            return Number(((long)v).ToString(CultureInfo.InvariantCulture), v);
        return Number(v.ToString("R", CultureInfo.InvariantCulture), v);
    }

    public JsonValue? this[string key] =>
        Kind == JsonKind.Object ? _object!.FirstOrDefault(m => m.Key == key).Value : null;

    public string? StringValue => Kind == JsonKind.String ? _raw : null;
    public bool? BoolValue => Kind == JsonKind.Bool ? _bool : null;
    public double? DoubleValue => Kind == JsonKind.Number ? _number : null;
    public string? RawNumber => Kind == JsonKind.Number ? _raw : null;
    /// <summary>The value as an exact integer within ±(2^53−1), or null.</summary>
    public long? IntValue =>
        Kind == JsonKind.Number && double.IsFinite(_number) && _number == Math.Round(_number)
            && Math.Abs(_number) <= 9_007_199_254_740_991 ? (long)_number : null;
    public IReadOnlyList<JsonValue>? ArrayValue => _array;
    public IReadOnlyList<KeyValuePair<string, JsonValue>>? ObjectMembers => _object;
    public bool IsNull => Kind == JsonKind.Null;

    /// <summary>Replace or append one member of an object; non-objects are returned unchanged.</summary>
    public JsonValue Setting(string key, JsonValue value)
    {
        if (Kind != JsonKind.Object) return this;
        var list = _object!.ToList();
        var i = list.FindIndex(m => m.Key == key);
        if (i >= 0) list[i] = new(key, value); else list.Add(new(key, value));
        return new JsonValue(JsonKind.Object, obj: list);
    }

    public bool Equals(JsonValue? other)
    {
        if (other is null || other.Kind != Kind) return false;
        switch (Kind)
        {
            case JsonKind.Null: return true;
            case JsonKind.Bool: return _bool == other._bool;
            case JsonKind.Number: return _number == other._number;
            case JsonKind.String: return string.Equals(_raw, other._raw, StringComparison.Ordinal);
            case JsonKind.Array:
                return _array!.Count == other._array!.Count && _array.Zip(other._array).All(p => p.First.Equals(p.Second));
            default:
                // JSON object equality ignores member order.
                if (_object!.Count != other._object!.Count) return false;
                var map = other._object.ToDictionary(m => m.Key, m => m.Value, StringComparer.Ordinal);
                return _object.All(m => map.TryGetValue(m.Key, out var v) && m.Value.Equals(v));
        }
    }

    public override bool Equals(object? obj) => obj is JsonValue v && Equals(v);
    public override int GetHashCode() => Kind switch
    {
        JsonKind.Bool => _bool.GetHashCode(),
        JsonKind.Number => _number.GetHashCode(),
        JsonKind.String => StringComparer.Ordinal.GetHashCode(_raw!),
        JsonKind.Array => _array!.Count,
        JsonKind.Object => _object!.Count,
        _ => 0,
    };
    public static bool operator ==(JsonValue? a, JsonValue? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(JsonValue? a, JsonValue? b) => !(a == b);

    /// <summary>Compact JSON, members in stored order. Never emits a line feed.</summary>
    public string Encoded()
    {
        var sb = new StringBuilder();
        Write(sb);
        return sb.ToString();
    }

    public byte[] EncodedBytes() => Encoding.UTF8.GetBytes(Encoded());

    public override string ToString() => Encoded();

    private void Write(StringBuilder sb)
    {
        switch (Kind)
        {
            case JsonKind.Null: sb.Append("null"); break;
            case JsonKind.Bool: sb.Append(_bool ? "true" : "false"); break;
            case JsonKind.Number: sb.Append(_raw); break;
            case JsonKind.String: WriteString(_raw!, sb); break;
            case JsonKind.Array:
                sb.Append('[');
                for (var i = 0; i < _array!.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    _array[i].Write(sb);
                }
                sb.Append(']');
                break;
            default:
                sb.Append('{');
                for (var i = 0; i < _object!.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    WriteString(_object[i].Key, sb);
                    sb.Append(':');
                    _object[i].Value.Write(sb);
                }
                sb.Append('}');
                break;
        }
    }

    private static void WriteString(string s, StringBuilder sb)
    {
        sb.Append('"');
        foreach (var rune in s.EnumerateRunes())
        {
            switch (rune.Value)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case 0x08: sb.Append("\\b"); break;
                case 0x0C: sb.Append("\\f"); break;
                default:
                    if (rune.Value < 0x20 || rune.Value == 0x2028 || rune.Value == 0x2029)
                        sb.Append("\\u").Append(rune.Value.ToString("x4", CultureInfo.InvariantCulture));
                    else
                        sb.Append(rune.ToString());
                    break;
            }
        }
        sb.Append('"');
    }
}

public enum StrictJsonErrorKind { Syntax, DuplicateKey, TooDeep, InvalidUtf8, TrailingData, NonFiniteNumber }

public sealed class StrictJsonException(StrictJsonErrorKind kind, int offset, string detail)
    : Exception($"{WireName(kind)} at byte {offset}: {detail}")
{
    public StrictJsonErrorKind Kind { get; } = kind;
    public int Offset { get; } = offset;
    public string Detail { get; } = detail;

    /// <summary>The same names Swift reports in error details.</summary>
    public static string WireName(StrictJsonErrorKind k) => k switch
    {
        StrictJsonErrorKind.Syntax => "syntax",
        StrictJsonErrorKind.DuplicateKey => "duplicateKey",
        StrictJsonErrorKind.TooDeep => "tooDeep",
        StrictJsonErrorKind.InvalidUtf8 => "invalidUTF8",
        StrictJsonErrorKind.TrailingData => "trailingData",
        _ => "nonFiniteNumber",
    };
}

/// <summary>
/// RFC 8259 parser that refuses what the wire contract forbids: duplicate
/// object keys, nesting beyond maxDepth, invalid UTF-8, lone surrogate
/// escapes, numbers that overflow to infinity, and anything after the single
/// top-level value.
/// </summary>
public static class StrictJson
{
    public const int DefaultMaxDepth = 64;
    private static readonly UTF8Encoding Utf8Strict = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static JsonValue Parse(string text, int maxDepth = DefaultMaxDepth) => Parse(Encoding.UTF8.GetBytes(text), maxDepth);

    public static JsonValue Parse(byte[] data, int maxDepth = DefaultMaxDepth)
    {
        var p = new Parser(data, maxDepth);
        p.SkipWhitespace();
        var v = p.ParseValue(0);
        p.SkipWhitespace();
        if (p.I != data.Length) throw new StrictJsonException(StrictJsonErrorKind.TrailingData, p.I, "data after the JSON value");
        return v;
    }

    private sealed class Parser(byte[] bytes, int maxDepth)
    {
        public int I;

        private StrictJsonException Fail(StrictJsonErrorKind kind, string detail) => new(kind, I, detail);

        public void SkipWhitespace()
        {
            while (I < bytes.Length && bytes[I] is 0x20 or 0x09 or 0x0A or 0x0D) I++;
        }

        public JsonValue ParseValue(int depth)
        {
            if (depth > maxDepth) throw Fail(StrictJsonErrorKind.TooDeep, $"nesting deeper than {maxDepth}");
            if (I >= bytes.Length) throw Fail(StrictJsonErrorKind.Syntax, "unexpected end of input");
            return bytes[I] switch
            {
                (byte)'{' => ParseObject(depth),
                (byte)'[' => ParseArray(depth),
                (byte)'"' => JsonValue.String(ParseString()),
                (byte)'t' => Literal("true", JsonValue.Bool(true)),
                (byte)'f' => Literal("false", JsonValue.Bool(false)),
                (byte)'n' => Literal("null", JsonValue.Null),
                (byte)'-' or (>= (byte)'0' and <= (byte)'9') => ParseNumber(),
                _ => throw Fail(StrictJsonErrorKind.Syntax, "unexpected character"),
            };
        }

        private JsonValue Literal(string word, JsonValue value)
        {
            foreach (var c in word)
            {
                if (I >= bytes.Length || bytes[I] != c) throw Fail(StrictJsonErrorKind.Syntax, "invalid literal");
                I++;
            }
            return value;
        }

        private JsonValue ParseObject(int depth)
        {
            I++;
            var members = new List<KeyValuePair<string, JsonValue>>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            SkipWhitespace();
            if (I < bytes.Length && bytes[I] == '}') { I++; return JsonValue.Object(members); }
            while (true)
            {
                SkipWhitespace();
                if (I >= bytes.Length || bytes[I] != '"') throw Fail(StrictJsonErrorKind.Syntax, "expected a key");
                var keyStart = I;
                var key = ParseString();
                if (!seen.Add(key)) throw new StrictJsonException(StrictJsonErrorKind.DuplicateKey, keyStart, $"duplicate key \"{key}\"");
                SkipWhitespace();
                if (I >= bytes.Length || bytes[I] != ':') throw Fail(StrictJsonErrorKind.Syntax, "expected ':'");
                I++;
                SkipWhitespace();
                members.Add(new(key, ParseValue(depth + 1)));
                SkipWhitespace();
                if (I >= bytes.Length) throw Fail(StrictJsonErrorKind.Syntax, "unterminated object");
                if (bytes[I] == ',') { I++; continue; }
                if (bytes[I] == '}') { I++; return JsonValue.Object(members); }
                throw Fail(StrictJsonErrorKind.Syntax, "expected ',' or '}'");
            }
        }

        private JsonValue ParseArray(int depth)
        {
            I++;
            var items = new List<JsonValue>();
            SkipWhitespace();
            if (I < bytes.Length && bytes[I] == ']') { I++; return JsonValue.Array(items); }
            while (true)
            {
                SkipWhitespace();
                items.Add(ParseValue(depth + 1));
                SkipWhitespace();
                if (I >= bytes.Length) throw Fail(StrictJsonErrorKind.Syntax, "unterminated array");
                if (bytes[I] == ',') { I++; continue; }
                if (bytes[I] == ']') { I++; return JsonValue.Array(items); }
                throw Fail(StrictJsonErrorKind.Syntax, "expected ',' or ']'");
            }
        }

        private uint ParseHex4()
        {
            if (I + 4 > bytes.Length) throw Fail(StrictJsonErrorKind.Syntax, "short \\u escape");
            uint v = 0;
            for (var k = 0; k < 4; k++)
            {
                var c = bytes[I];
                uint d = c switch
                {
                    >= (byte)'0' and <= (byte)'9' => (uint)(c - '0'),
                    >= (byte)'a' and <= (byte)'f' => (uint)(c - 'a' + 10),
                    >= (byte)'A' and <= (byte)'F' => (uint)(c - 'A' + 10),
                    _ => throw Fail(StrictJsonErrorKind.Syntax, "bad hex digit"),
                };
                v = v * 16 + d;
                I++;
            }
            return v;
        }

        private string ParseString()
        {
            I++;
            var sb = new StringBuilder();
            var runStart = I;
            void Flush(int end)
            {
                if (end <= runStart) return;
                try { sb.Append(Utf8Strict.GetString(bytes, runStart, end - runStart)); }
                catch (DecoderFallbackException) { throw Fail(StrictJsonErrorKind.InvalidUtf8, "invalid UTF-8 in string"); }
            }
            while (true)
            {
                if (I >= bytes.Length) throw Fail(StrictJsonErrorKind.Syntax, "unterminated string");
                var c = bytes[I];
                if (c == '"')
                {
                    Flush(I);
                    I++;
                    return sb.ToString();
                }
                if (c < 0x20) throw Fail(StrictJsonErrorKind.Syntax, "control character in string");
                if (c == '\\')
                {
                    Flush(I);
                    I++;
                    if (I >= bytes.Length) throw Fail(StrictJsonErrorKind.Syntax, "bad escape");
                    var e = bytes[I];
                    I++;
                    switch (e)
                    {
                        case (byte)'"': sb.Append('"'); break;
                        case (byte)'\\': sb.Append('\\'); break;
                        case (byte)'/': sb.Append('/'); break;
                        case (byte)'b': sb.Append('\b'); break;
                        case (byte)'f': sb.Append('\f'); break;
                        case (byte)'n': sb.Append('\n'); break;
                        case (byte)'r': sb.Append('\r'); break;
                        case (byte)'t': sb.Append('\t'); break;
                        case (byte)'u':
                            var hi = ParseHex4();
                            var code = hi;
                            if (hi is >= 0xD800 and <= 0xDBFF)
                            {
                                if (I + 1 >= bytes.Length || bytes[I] != '\\' || bytes[I + 1] != 'u')
                                    throw Fail(StrictJsonErrorKind.Syntax, "lone high surrogate");
                                I += 2;
                                var lo = ParseHex4();
                                if (lo is < 0xDC00 or > 0xDFFF) throw Fail(StrictJsonErrorKind.Syntax, "bad low surrogate");
                                code = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                            }
                            else if (hi is >= 0xDC00 and <= 0xDFFF)
                            {
                                throw Fail(StrictJsonErrorKind.Syntax, "lone low surrogate");
                            }
                            sb.Append(new Rune(code).ToString());
                            break;
                        default: throw Fail(StrictJsonErrorKind.Syntax, "bad escape");
                    }
                    runStart = I;
                    continue;
                }
                I++;
            }
        }

        private bool Digit() => I < bytes.Length && bytes[I] is >= (byte)'0' and <= (byte)'9';

        private JsonValue ParseNumber()
        {
            var start = I;
            if (bytes[I] == '-') I++;
            if (!Digit()) throw Fail(StrictJsonErrorKind.Syntax, "bad number");
            if (bytes[I] == '0')
            {
                I++;
                if (Digit()) throw Fail(StrictJsonErrorKind.Syntax, "leading zero");
            }
            else
            {
                while (Digit()) I++;
            }
            if (I < bytes.Length && bytes[I] == '.')
            {
                I++;
                if (!Digit()) throw Fail(StrictJsonErrorKind.Syntax, "bad fraction");
                while (Digit()) I++;
            }
            if (I < bytes.Length && bytes[I] is (byte)'e' or (byte)'E')
            {
                I++;
                if (I < bytes.Length && bytes[I] is (byte)'+' or (byte)'-') I++;
                if (!Digit()) throw Fail(StrictJsonErrorKind.Syntax, "bad exponent");
                while (Digit()) I++;
            }
            var raw = Encoding.ASCII.GetString(bytes, start, I - start);
            var v = double.Parse(raw, NumberStyles.Float, CultureInfo.InvariantCulture);
            if (!double.IsFinite(v)) throw new StrictJsonException(StrictJsonErrorKind.NonFiniteNumber, start, "number out of range");
            return JsonValue.Number(raw, v);
        }
    }
}

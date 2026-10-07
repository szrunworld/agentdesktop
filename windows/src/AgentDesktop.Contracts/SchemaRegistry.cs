using System.Globalization;
using System.Text.RegularExpressions;

namespace AgentDesktop.Contracts;

/// <summary>One way an instance fails its schema. Path is a JSON pointer ("" is the root).</summary>
public sealed record SchemaViolation(string Path, string Keyword, string Message)
{
    public override string ToString() => $"{(Path.Length == 0 ? "/" : Path)}: {Keyword}: {Message}";
}

public sealed class SchemaException(string message) : Exception(message);

/// <summary>
/// JSON Schema 2020-12 validator for the keywords the AgentDesktop AI/GUI
/// contract uses. Unknown assertion keywords are refused when a document is
/// loaded, so a schema change that needs a new keyword fails loudly instead
/// of being silently ignored. format is asserted (date-time, uuid, uri).
/// Mirrors Swift's SchemaRegistry.
/// </summary>
public sealed class SchemaRegistry
{
    public static readonly IReadOnlySet<string> AssertionKeywords = new HashSet<string>
    {
        "type", "enum", "const",
        "minLength", "maxLength", "pattern", "format",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "required", "properties", "additionalProperties", "minProperties", "maxProperties",
        "dependentRequired",
        "items", "prefixItems", "minItems", "maxItems", "uniqueItems",
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
        "$ref",
    };

    public static readonly IReadOnlySet<string> AnnotationKeywords = new HashSet<string>
    {
        "$schema", "$id", "$defs", "title", "description", "writeOnly", "readOnly",
        "default", "examples", "$comment", "deprecated",
    };

    private readonly Dictionary<string, JsonValue> _documents = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Regex> _regexCache = new(StringComparer.Ordinal);
    private readonly object _lock = new();

    public string Add(JsonValue document)
    {
        var id = document["$id"]?.StringValue;
        if (id is null || !Uri.TryCreate(id, UriKind.Absolute, out _))
            throw new SchemaException("schema document needs an absolute $id");
        CheckKeywords(document, "");
        lock (_lock) _documents[id] = document;
        return id;
    }

    public string Add(byte[] json) => Add(StrictJson.Parse(json));

    public IReadOnlyCollection<string> DocumentIds { get { lock (_lock) return _documents.Keys.ToList(); } }

    public JsonValue Schema(string documentId, string pointer)
    {
        JsonValue? doc;
        lock (_lock) _documents.TryGetValue(documentId, out doc);
        if (doc is null) throw new SchemaException($"unknown document {documentId}");
        return ResolvePointer(pointer, doc) ?? throw new SchemaException($"unresolved reference {documentId}#{pointer}");
    }

    public IReadOnlyList<SchemaViolation> Validate(JsonValue instance, string documentId, string pointer, int limit = 50)
    {
        var schema = Schema(documentId, pointer);
        var ctx = new Context(this, limit);
        ctx.Validate(instance, schema, documentId, "");
        return ctx.Violations;
    }

    private static void CheckKeywords(JsonValue schema, string location)
    {
        if (schema.Kind == JsonKind.Bool) return;
        if (schema.Kind != JsonKind.Object)
            throw new SchemaException($"schema at {location} is neither object nor boolean");
        foreach (var m in schema.ObjectMembers!)
        {
            var here = $"{location}/{m.Key}";
            if (m.Key is "$defs" or "properties")
            {
                var sub = m.Value.ObjectMembers ?? throw new SchemaException(here);
                foreach (var s in sub) CheckKeywords(s.Value, $"{here}/{s.Key}");
                continue;
            }
            if (m.Key == "dependentRequired") continue;
            if (!AssertionKeywords.Contains(m.Key) && !AnnotationKeywords.Contains(m.Key))
                throw new SchemaException($"unsupported keyword {m.Key} at {(location.Length == 0 ? "/" : location)}");
            switch (m.Key)
            {
                case "items" or "not" or "if" or "then" or "else" or "additionalProperties":
                    CheckKeywords(m.Value, here);
                    break;
                case "allOf" or "anyOf" or "oneOf" or "prefixItems":
                    var arr = m.Value.ArrayValue ?? throw new SchemaException(here);
                    for (var i = 0; i < arr.Count; i++) CheckKeywords(arr[i], $"{here}/{i}");
                    break;
            }
        }
    }

    internal static JsonValue? ResolvePointer(string pointer, JsonValue doc)
    {
        if (pointer.Length == 0 || pointer == "/") return doc;
        var cur = doc;
        foreach (var rawPart in pointer.Split('/').Skip(1))
        {
            var part = rawPart.Replace("~1", "/", StringComparison.Ordinal).Replace("~0", "~", StringComparison.Ordinal);
            if (cur.ArrayValue is { } arr)
            {
                if (!int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var idx) || idx >= arr.Count) return null;
                cur = arr[idx];
            }
            else if (cur[part] is { } next)
            {
                cur = next;
            }
            else
            {
                return null;
            }
        }
        return cur;
    }

    private (JsonValue Schema, string DocId) ResolveRef(string reference, string docId)
    {
        var hash = reference.IndexOf('#', StringComparison.Ordinal);
        var docPart = hash < 0 ? reference : reference[..hash];
        var fragment = hash < 0 ? "" : reference[(hash + 1)..];
        var target = docId;
        if (docPart.Length > 0)
        {
            if (!Uri.TryCreate(new Uri(docId), docPart, out var url)) throw new SchemaException($"unresolved reference {reference}");
            target = url.AbsoluteUri;
        }
        return (Schema(target, fragment), target);
    }

    private Regex RegexFor(string pattern)
    {
        lock (_lock)
        {
            if (_regexCache.TryGetValue(pattern, out var r)) return r;
            try { r = new Regex(pattern, RegexOptions.CultureInvariant); }
            catch (ArgumentException) { throw new SchemaException($"pattern does not compile: {pattern}"); }
            _regexCache[pattern] = r;
            return r;
        }
    }

    private sealed class Context(SchemaRegistry registry, int limit)
    {
        public readonly List<SchemaViolation> Violations = [];
        private int _refDepth;

        private void Add(string path, string keyword, string message)
        {
            if (Violations.Count < limit) Violations.Add(new SchemaViolation(path, keyword, message));
        }

        private bool Passes(JsonValue instance, JsonValue schema, string docId, string path)
        {
            var scratch = new Context(registry, 1) { _refDepth = _refDepth };
            scratch.Validate(instance, schema, docId, path);
            return scratch.Violations.Count == 0;
        }

        public void Validate(JsonValue instance, JsonValue schema, string docId, string path)
        {
            if (schema.Kind == JsonKind.Bool)
            {
                if (schema.BoolValue == false) Add(path, "false", "no value is allowed here");
                return;
            }
            if (schema.Kind != JsonKind.Object) throw new SchemaException("non-object schema");

            if (schema["$ref"]?.StringValue is { } reference)
            {
                _refDepth++;
                try
                {
                    if (_refDepth >= 64) throw new SchemaException($"$ref recursion too deep at {reference}");
                    var (target, targetDoc) = registry.ResolveRef(reference, docId);
                    Validate(instance, target, targetDoc, path);
                }
                finally { _refDepth--; }
            }

            if (schema["type"] is { } t)
            {
                var types = t.ArrayValue?.Select(x => x.StringValue).OfType<string>().ToList()
                            ?? (t.StringValue is { } one ? [one] : []);
                if (!types.Any(type => IsType(instance, type)))
                {
                    Add(path, "type", $"expected {string.Join(" or ", types)}");
                    return;
                }
            }
            if (schema["const"] is { } c && c != instance) Add(path, "const", $"must equal {c.Encoded()}");
            if (schema["enum"]?.ArrayValue is { } e && !e.Contains(instance))
                Add(path, "enum", $"must be one of {string.Join(", ", e.Select(x => x.Encoded()))}");

            switch (instance.Kind)
            {
                case JsonKind.String:
                    var s = instance.StringValue!;
                    var len = s.EnumerateRunes().Count();
                    if (schema["minLength"]?.IntValue is { } minL && len < minL) Add(path, "minLength", $"shorter than {minL}");
                    if (schema["maxLength"]?.IntValue is { } maxL && len > maxL) Add(path, "maxLength", $"longer than {maxL}");
                    if (schema["pattern"]?.StringValue is { } p && !registry.RegexFor(p).IsMatch(s))
                        Add(path, "pattern", $"does not match {p}");
                    if (schema["format"]?.StringValue is { } f && !Formats.Check(f, s)) Add(path, "format", $"not a valid {f}");
                    break;
                case JsonKind.Number:
                    var v = instance.DoubleValue!.Value;
                    if (schema["minimum"]?.DoubleValue is { } min && v < min) Add(path, "minimum", $"less than {min}");
                    if (schema["maximum"]?.DoubleValue is { } max && v > max) Add(path, "maximum", $"greater than {max}");
                    if (schema["exclusiveMinimum"]?.DoubleValue is { } xmin && v <= xmin) Add(path, "exclusiveMinimum", $"not greater than {xmin}");
                    if (schema["exclusiveMaximum"]?.DoubleValue is { } xmax && v >= xmax) Add(path, "exclusiveMaximum", $"not less than {xmax}");
                    break;
                case JsonKind.Array:
                    var items = instance.ArrayValue!;
                    if (schema["minItems"]?.IntValue is { } minI && items.Count < minI) Add(path, "minItems", $"fewer than {minI} items");
                    if (schema["maxItems"]?.IntValue is { } maxI && items.Count > maxI) Add(path, "maxItems", $"more than {maxI} items");
                    if (schema["uniqueItems"]?.BoolValue == true)
                        for (var i = 0; i < items.Count; i++)
                            if (items.Take(i).Contains(items[i])) Add($"{path}/{i}", "uniqueItems", "duplicate item");
                    var start = 0;
                    if (schema["prefixItems"]?.ArrayValue is { } prefix)
                    {
                        for (var i = 0; i < prefix.Count && i < items.Count; i++) Validate(items[i], prefix[i], docId, $"{path}/{i}");
                        start = prefix.Count;
                    }
                    if (schema["items"] is { } itemSchema)
                        for (var i = start; i < items.Count; i++) Validate(items[i], itemSchema, docId, $"{path}/{i}");
                    break;
                case JsonKind.Object:
                    var members = instance.ObjectMembers!;
                    var keys = members.Select(m => m.Key).ToHashSet(StringComparer.Ordinal);
                    if (schema["minProperties"]?.IntValue is { } minP && members.Count < minP) Add(path, "minProperties", $"fewer than {minP} members");
                    if (schema["maxProperties"]?.IntValue is { } maxP && members.Count > maxP) Add(path, "maxProperties", $"more than {maxP} members");
                    foreach (var r in schema["required"]?.ArrayValue?.Select(x => x.StringValue).OfType<string>() ?? [])
                        if (!keys.Contains(r)) Add(path, "required", $"missing \"{r}\"");
                    if (schema["dependentRequired"]?.ObjectMembers is { } dr)
                        foreach (var d in dr)
                            if (keys.Contains(d.Key))
                                foreach (var need in d.Value.ArrayValue?.Select(x => x.StringValue).OfType<string>() ?? [])
                                    if (!keys.Contains(need)) Add(path, "dependentRequired", $"\"{d.Key}\" requires \"{need}\"");
                    var props = (schema["properties"]?.ObjectMembers ?? []).ToDictionary(x => x.Key, x => x.Value, StringComparer.Ordinal);
                    foreach (var m in members)
                    {
                        var child = $"{path}/{Escape(m.Key)}";
                        if (props.TryGetValue(m.Key, out var ps))
                        {
                            Validate(m.Value, ps, docId, child);
                        }
                        else if (schema["additionalProperties"] is { } ap)
                        {
                            if (ap.Kind == JsonKind.Bool && ap.BoolValue == false)
                                Add(child, "additionalProperties", $"unknown member \"{m.Key}\"");
                            else
                                Validate(m.Value, ap, docId, child);
                        }
                    }
                    break;
            }

            if (schema["allOf"]?.ArrayValue is { } all)
                foreach (var sub in all) Validate(instance, sub, docId, path);
            if (schema["anyOf"]?.ArrayValue is { } any && !any.Any(sub => Passes(instance, sub, docId, path)))
                Add(path, "anyOf", $"matches none of {any.Count} alternatives");
            if (schema["oneOf"]?.ArrayValue is { } oneOf)
            {
                var n = oneOf.Count(sub => Passes(instance, sub, docId, path));
                if (n != 1) Add(path, "oneOf", $"matches {n} of {oneOf.Count} alternatives, expected exactly 1");
            }
            if (schema["not"] is { } not && Passes(instance, not, docId, path)) Add(path, "not", "matches a forbidden schema");
            if (schema["if"] is { } cond)
            {
                if (Passes(instance, cond, docId, path))
                {
                    if (schema["then"] is { } then) Validate(instance, then, docId, path);
                }
                else if (schema["else"] is { } els)
                {
                    Validate(instance, els, docId, path);
                }
            }
        }

        private static string Escape(string key) =>
            key.Replace("~", "~0", StringComparison.Ordinal).Replace("/", "~1", StringComparison.Ordinal);

        private static bool IsType(JsonValue v, string t) => (t, v.Kind) switch
        {
            ("null", JsonKind.Null) or ("boolean", JsonKind.Bool) or ("string", JsonKind.String)
                or ("array", JsonKind.Array) or ("object", JsonKind.Object) or ("number", JsonKind.Number) => true,
            ("integer", JsonKind.Number) => v.IntValue is not null,
            _ => false,
        };
    }
}

/// <summary>Assertions for the format values the contract uses.</summary>
public static partial class Formats
{
    [GeneratedRegex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", RegexOptions.CultureInvariant)]
    private static partial Regex Uuid();

    [GeneratedRegex("^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(\\.[0-9]+)?([Zz]|[+-]([0-9]{2}):([0-9]{2}))$", RegexOptions.CultureInvariant)]
    private static partial Regex DateTime();

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9+.-]*:", RegexOptions.CultureInvariant)]
    private static partial Regex Scheme();

    public static bool Check(string format, string s)
    {
        switch (format)
        {
            case "uuid":
                return Uuid().IsMatch(s);
            case "date-time":
                var m = DateTime().Match(s);
                if (!m.Success) return false;
                int N(int i) => int.Parse(m.Groups[i].Value, CultureInfo.InvariantCulture);
                var (y, mo, d, h, mi, se) = (N(1), N(2), N(3), N(4), N(5), N(6));
                var leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
                int[] days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
                if (mo is < 1 or > 12 || d < 1 || d > days[mo - 1] || h >= 24 || mi >= 60 || se >= 61) return false;
                if (m.Groups[9].Success) return N(9) < 24 && N(10) < 60;
                return true;
            case "uri":
                return Scheme().IsMatch(s) && Uri.TryCreate(s, UriKind.Absolute, out _);
            default:
                return true;
        }
    }
}

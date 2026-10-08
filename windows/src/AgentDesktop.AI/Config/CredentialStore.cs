using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace AgentDesktop.AI.Config;

/// <summary>
/// Holds API keys outside the configuration database. Only the credential id
/// (a random reference) ever appears in SQLite, responses or logs.
/// </summary>
public interface ICredentialStore
{
    void Write(string credentialId, string secret);
    /// <summary>Null when no secret is stored under this id.</summary>
    string? Read(string credentialId);
    /// <summary>Idempotent: deleting a missing id succeeds.</summary>
    void Delete(string credentialId);
}

public sealed class CredentialStoreException(string operation, string message) : Exception(message)
{
    public string Operation { get; } = operation;
}

/// <summary>In-process store for tests, with injectable failures.</summary>
public sealed class InMemoryCredentialStore : ICredentialStore
{
    public enum Op { Write, Read, Delete }

    private readonly Lock _lock = new();
    private readonly Dictionary<string, string> _items = new(StringComparer.Ordinal);
    private readonly HashSet<Op> _failing = [];

    public void Fail(Op op, bool on = true)
    {
        lock (_lock) { if (on) _failing.Add(op); else _failing.Remove(op); }
    }

    private void Check(Op op)
    {
        if (_failing.Contains(op)) throw new CredentialStoreException(op.ToString(), "injected failure");
    }

    public void Write(string credentialId, string secret)
    {
        lock (_lock) { Check(Op.Write); _items[credentialId] = secret; }
    }

    public string? Read(string credentialId)
    {
        lock (_lock) { Check(Op.Read); return _items.GetValueOrDefault(credentialId); }
    }

    public void Delete(string credentialId)
    {
        lock (_lock) { Check(Op.Delete); _items.Remove(credentialId); }
    }

    public IReadOnlySet<string> StoredIds
    {
        get { lock (_lock) return _items.Keys.ToHashSet(StringComparer.Ordinal); }
    }

    /// <summary>Remove an item behind the service's back (lost or locked secret).</summary>
    public void Drop(string credentialId)
    {
        lock (_lock) _items.Remove(credentialId);
    }
}

/// <summary>
/// Windows: each secret encrypted with DPAPI for the current user (spec
/// §03.3) in its own file under a directory whose ACL grants only the
/// current user. DPAPI CurrentUser protects against other users, not
/// against another process of the same user.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class DpapiCredentialStore : ICredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("com.agentdesktop.ai.credentials");
    public string Directory { get; }

    /// <param name="directory">Default: %LOCALAPPDATA%\AgentDesktop\credentials.</param>
    public DpapiCredentialStore(string? directory = null)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("DPAPI credentials exist only on Windows");
        Directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentDesktop", "credentials");
        var info = new DirectoryInfo(Directory);
        info.Create();
        info.SetAccessControl(PrivateAcl());
    }

    /// <summary>Full control for the current user only; no inherited entries.</summary>
    public static DirectorySecurity PrivateAcl()
    {
        var acl = new DirectorySecurity();
        acl.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var me = WindowsIdentity.GetCurrent().User ?? throw new CredentialStoreException("acl", "no current user");
        acl.SetOwner(me);
        acl.AddAccessRule(new FileSystemAccessRule(me, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        return acl;
    }

    private string FileFor(string credentialId) =>
        Path.Combine(Directory, Convert.ToHexString(Encoding.UTF8.GetBytes(credentialId)) + ".bin");

    public void Write(string credentialId, string secret)
    {
        var sealedBytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(secret), Entropy, DataProtectionScope.CurrentUser);
        var path = FileFor(credentialId);
        var tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(tmp, sealedBytes);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(tmp); } catch (IOException) { }
            throw new CredentialStoreException("write", e.GetType().Name);
        }
    }

    public string? Read(string credentialId)
    {
        var path = FileFor(credentialId);
        if (!File.Exists(path)) return null;
        try
        {
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
        {
            throw new CredentialStoreException("read", e.GetType().Name);
        }
    }

    public void Delete(string credentialId)
    {
        try { File.Delete(FileFor(credentialId)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new CredentialStoreException("delete", e.GetType().Name);
        }
    }
}

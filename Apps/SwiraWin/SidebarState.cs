using System.Text.Json;

namespace SwiraWin;

/// Persists which filter-tree branches are expanded, keyed by full path (CLIENT-SPEC.md §2.2:
/// "keyed by its full path, not a transient identity like a DOM node or list index"). One JSON
/// file under the user's local app data, same spirit as SwiraCore's own on-disk cache.
internal static class SidebarState
{
    private static string FilePath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Swira", "sidebar-state.json");

    public static HashSet<string> LoadExpandedPaths()
    {
        try
        {
            var json = File.ReadAllText(FilePath);
            var paths = JsonSerializer.Deserialize<string[]>(json);
            return paths is null ? [] : [.. paths];
        }
        catch
        {
            return [];
        }
    }

    public static void SaveExpandedPaths(IEnumerable<string> paths)
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(paths));
        }
        catch
        {
            // Best effort — losing expand state on write failure isn't worth surfacing an error
            // for.
        }
    }
}

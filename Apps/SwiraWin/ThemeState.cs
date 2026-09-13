namespace SwiraWin;

/// The user's explicit theme override — Light/Dark/System — persisted the same way as
/// `SidebarState`. `System` means "no override": follow the OS setting, same as if this feature
/// didn't exist.
internal enum AppTheme { System, Light, Dark }

internal static class ThemeState
{
    private static string FilePath =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Swira", "theme.txt");

    public static AppTheme Load()
    {
        try
        {
            var text = File.ReadAllText(FilePath).Trim();
            return Enum.TryParse<AppTheme>(text, out var theme) ? theme : AppTheme.System;
        }
        catch
        {
            return AppTheme.System;
        }
    }

    public static void Save(AppTheme theme)
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(FilePath, theme.ToString());
        }
        catch
        {
            // Best effort — same spirit as SidebarState.SaveExpandedPaths.
        }
    }
}

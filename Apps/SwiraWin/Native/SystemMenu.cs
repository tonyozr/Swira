using System.Runtime.InteropServices;

namespace SwiraWin.Native;

/// Appends Light/Dark/System theme entries to the window's classic Win32 system menu — the one
/// opened via the title-bar icon, right-clicking the title bar, or Alt+Space, present on every
/// Win32 window since long before WinUI existed and still just an ordinary HMENU under a WinUI3
/// desktop window's HWND. The user specifically asked for it to live there rather than in an
/// always-visible toolbar control or a hamburger menu, precisely because it's rarely needed.
///
/// This requires two pieces Win32 doesn't give you any higher-level API for: appending to the
/// system menu itself (`GetSystemMenu`/`AppendMenu`), and catching the `WM_SYSCOMMAND` message a
/// chosen item sends — which means subclassing the window's own WndProc, since WinUI's managed
/// event surface has no hook for system-menu commands.
internal sealed class SystemMenu
{
    private const int WM_SYSCOMMAND = 0x0112;
    private const int MF_STRING = 0x0000;
    private const int MF_SEPARATOR = 0x0800;
    private const int MF_CHECKED = 0x0008;
    private const int MF_UNCHECKED = 0x0000;
    private const int MF_BYCOMMAND = 0x0000;
    private const int GWLP_WNDPROC = -4;

    // Below 0xF000 — that range is reserved for the standard SC_* system commands
    // (SC_CLOSE, SC_MINIMIZE, ...); anything else is fair game for custom ids.
    private const int IdLight = 0x100;
    private const int IdDark = 0x101;
    private const int IdSystem = 0x102;

    [DllImport("user32.dll")] private static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(IntPtr hMenu, int uFlags, IntPtr uIDNewItem, string? lpNewItem);
    [DllImport("user32.dll")] private static extern bool CheckMenuItem(IntPtr hMenu, int uIDCheckItem, int uCheck);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    [DllImport("user32.dll")]
    private static extern IntPtr CallWindowProc(IntPtr lpPrevWndFunc, IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    private readonly IntPtr _hwnd;
    private readonly IntPtr _hMenu;
    private readonly Action<AppTheme> _onThemeChosen;
    // Kept alive for the process lifetime — SetWindowLongPtr only stores a raw function pointer,
    // so the delegate itself must not be collected out from under it.
    private readonly WndProcDelegate _wndProc;
    private readonly IntPtr _originalWndProc;

    public SystemMenu(IntPtr hwnd, AppTheme initial, Action<AppTheme> onThemeChosen)
    {
        _hwnd = hwnd;
        _onThemeChosen = onThemeChosen;
        _hMenu = GetSystemMenu(hwnd, false);

        AppendMenuW(_hMenu, MF_SEPARATOR, IntPtr.Zero, null);
        AppendMenuW(_hMenu, MF_STRING, (IntPtr)IdLight, "Light theme");
        AppendMenuW(_hMenu, MF_STRING, (IntPtr)IdDark, "Dark theme");
        AppendMenuW(_hMenu, MF_STRING, (IntPtr)IdSystem, "Match system");
        UpdateCheckmark(initial);

        _wndProc = WndProc;
        var wndProcPtr = Marshal.GetFunctionPointerForDelegate(_wndProc);
        _originalWndProc = SetWindowLongPtr64(hwnd, GWLP_WNDPROC, wndProcPtr);
    }

    /// Reflects the active theme as a checkmark next to its entry — same as any other tri-state
    /// system-menu option (compare Aero Snap's items, which do the same).
    public void UpdateCheckmark(AppTheme theme)
    {
        CheckMenuItem(_hMenu, IdLight, theme == AppTheme.Light ? MF_CHECKED : MF_UNCHECKED);
        CheckMenuItem(_hMenu, IdDark, theme == AppTheme.Dark ? MF_CHECKED : MF_UNCHECKED);
        CheckMenuItem(_hMenu, IdSystem, theme == AppTheme.System ? MF_CHECKED : MF_UNCHECKED);
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_SYSCOMMAND)
        {
            // No `& 0xFFF0` here: that mask exists so code comparing against Windows' own SC_*
            // constants (SC_SIZE, SC_MOVE, ...) can ignore their low 4 bits, which the system
            // uses for auxiliary flags (SC_MOUSEMENU, keyboard-vs-mouse invocation, etc.) — those
            // constants are themselves chosen as multiples of 16 specifically so that masking
            // doesn't change which command they name. Our own custom ids (0x100/0x101/0x102) are
            // NOT spaced that way; masking them collapsed all three down to 0x100, so every theme
            // choice silently resolved to Light regardless of which one was actually clicked —
            // confirmed live: Dark and Match System both persisted "Light" to disk every time.
            var id = wParam.ToInt32();
            switch (id)
            {
                case IdLight: _onThemeChosen(AppTheme.Light); return IntPtr.Zero;
                case IdDark: _onThemeChosen(AppTheme.Dark); return IntPtr.Zero;
                case IdSystem: _onThemeChosen(AppTheme.System); return IntPtr.Zero;
            }
        }
        return CallWindowProc(_originalWndProc, hWnd, msg, wParam, lParam);
    }
}

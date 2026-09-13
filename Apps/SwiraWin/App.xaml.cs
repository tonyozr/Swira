using Microsoft.UI.Xaml;

namespace SwiraWin;

/// Entry point. Owns the single top-level window the whole client lives in — Swira presents
/// exactly one window (docs/CLIENT-SPEC.md §1); there is no multi-window flow to wire up here.
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}

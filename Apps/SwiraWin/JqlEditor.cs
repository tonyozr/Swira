using System.Text.RegularExpressions;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace SwiraWin;

public sealed class ChipTappedEventArgs(string filterId, bool ctrlHeld) : EventArgs
{
    public string FilterId { get; } = filterId;
    public bool CtrlHeld { get; } = ctrlHeld;
}

/// <summary>
/// A from-scratch JQL text editor, replacing the <c>RichEditBox</c> this app started with.
/// RichEditBox turned out to be the wrong tool for this specific job, for two concrete, lived-with
/// reasons rather than a hunch: (1) its legacy RichEdit COM internals have no supported way to map
/// a screen point to a text position — confirmed by exhaustive live testing (neither a plain click
/// nor a Ctrl-click on a chip ever registered as landing inside its character range under synthetic
/// input, and the drag-drop insertion point had to fall back to "wherever the caret already was"
/// instead of the actual drop location, a documented spec deviation); (2) it resets scroll position
/// to the top of the document on reformatting, which this app does on essentially every edit.
///
/// Built entirely in code, not XAML — this project's established pattern for anything nonstandard
/// (see CLAUDE.md's notes on this environment's XamlCompiler crashing outright, with no usable
/// diagnostic, on `GroupStyle`, custom `DataTemplateSelector`s, and certain `Grid`+`Visibility`
/// shapes). A brand new custom control's visual tree is exactly the kind of surface most likely to
/// hit an undiscovered case of that, so it isn't worth the risk when building it in C# works fine.
///
/// Rendering model: `Text` is always plain JQL — no more invisible-character chip-marking trick,
/// because there's no longer a painted-character-formatting layer to hide markers in. Every render
/// pass parses `Text` into a flat sequence of spans — a filter reference (`filter = &lt;id&gt;`,
/// rendered as a real `Border`+`TextBlock` chip with its own `Tapped` handler) or plain text
/// (tokenized further for syntax-highlight coloring and click granularity) — and lays them out as
/// real, independently hit-testable `UIElement`s. That's what makes chip clicks, drop-position
/// resolution, and caret placement all just ordinary hit-testing instead of something to
/// reverse-engineer from RichEdit's internals.
///
/// Caret precision: keyboard-driven movement and typing are exact (a plain integer index into
/// `Text`). Pointer-driven placement (click, drop) snaps to the nearest token boundary, since
/// that's what token-granularity hit-testing can resolve directly — a documented v1 simplification,
/// not an oversight; refining it to sub-token pixel precision would mean a run per character.
/// </summary>
public sealed class JqlEditor : ContentControl
{
    private static readonly Regex FilterReferencePattern = new(@"\bfilter\s*=\s*(\d+)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex TokenPattern = new("\"[^\"]*\"|'[^']*'|\\S+|\\s+", RegexOptions.Compiled);
    private static readonly Regex JqlStringPattern = new("^(\"[^\"]*\"|'[^']*')$", RegexOptions.Compiled);
    private static readonly Regex JqlFunctionPattern = new(
        @"\b(currentUser|membersOf|now|startOfDay|endOfDay|startOfWeek|endOfWeek|startOfMonth|endOfMonth|linkedIssues|issueHistory|openSprints|closedSprints)\s*\(",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex JqlKeywordPattern = new(
        @"^(AND|OR|NOT|IN|IS|WAS|CHANGED|EMPTY|NULL|ORDER BY|ASC|DESC|ON|BY|DURING|BEFORE|AFTER|FROM|TO)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex JqlNumberPattern = new(@"^\d+[dwhm]?$", RegexOptions.Compiled);

    private static readonly Windows.UI.Color JqlStringColor = Windows.UI.Color.FromArgb(255, 0xCE, 0x91, 0x78);
    private static readonly Windows.UI.Color JqlFunctionColor = Windows.UI.Color.FromArgb(255, 0x4E, 0xC9, 0xB0);
    private static readonly Windows.UI.Color JqlKeywordColor = Windows.UI.Color.FromArgb(255, 0x56, 0x9C, 0xD6);
    private static readonly Windows.UI.Color JqlNumberColor = Windows.UI.Color.FromArgb(255, 0xB5, 0xCE, 0xA8);
    private static readonly Windows.UI.Color ChipBackgroundColor = Windows.UI.Color.FromArgb(255, 0x3B, 0x6E, 0xA5);
    private static readonly Windows.UI.Color ChipForegroundColor = Windows.UI.Color.FromArgb(255, 0xFF, 0xFF, 0xFF);
    private static readonly Windows.UI.Color SelectionColor = Windows.UI.Color.FromArgb(90, 0x56, 0x9C, 0xD6);

    private readonly Grid _root;
    private readonly ScrollViewer _scroller;
    private readonly StackPanel _lines;
    private readonly Canvas _overlay;
    private readonly Rectangle _caretVisual;

    private sealed record RunInfo(int Start, int End, FrameworkElement Element, string? ChipId);
    private readonly List<RunInfo> _runs = [];

    private string _text = "";
    private int _caretIndex;
    private int? _selectionAnchor;

    public event EventHandler? TextChanged;
    public event EventHandler<ChipTappedEventArgs>? ChipTapped;

    /// Resolves a filter id (as it appears in `filter = &lt;id&gt;`) to the name a chip should
    /// display. Injected rather than baked in — this control has no idea what filters exist,
    /// only the host window does.
    public Func<string, string?>? ResolveFilterName { get; set; }

    public string Text
    {
        get => _text;
        set
        {
            if (_text == value) return;
            _text = value;
            _caretIndex = Math.Clamp(_caretIndex, 0, _text.Length);
            _selectionAnchor = null;
            Render();
            TextChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// Re-renders with freshly-resolved theme colors. Needed because a theme switch changes
    /// `ActualTheme` without touching `Text` or firing `SizeChanged` — the two things a normal
    /// `Render()` call is triggered by — so nothing else would prompt this control to notice.
    public void RefreshTheme() => Render();

    public int CaretIndex
    {
        get => _caretIndex;
        set
        {
            _caretIndex = Math.Clamp(value, 0, _text.Length);
            _selectionAnchor = null;
            PositionCaret();
        }
    }

    public JqlEditor()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AllowDrop = true;

        _lines = new StackPanel { Orientation = Orientation.Vertical };
        _overlay = new Canvas { IsHitTestVisible = false };
        _caretVisual = new Rectangle { Width = 2, Fill = new SolidColorBrush(DefaultForegroundColor()), Visibility = Visibility.Collapsed };
        _overlay.Children.Add(_caretVisual);

        // VerticalAlignment.Top is load-bearing: a Grid handed to ScrollViewer.Content defaults
        // to Stretch, which makes it accept exactly the viewport's height and report that back as
        // its own desired size — the ScrollViewer then sees nothing taller than the viewport and
        // never scrolls. Confirmed live: with Stretch, everything past ~240px got laid out with
        // collapsed (near-zero-height/Empty) bounds instead of just scrolling into view. Top
        // alignment makes the Grid (and `_lines` inside it) report their true, unclamped content
        // height instead, which is what actually gives the ScrollViewer a scrollable extent.
        var content = new Grid { VerticalAlignment = VerticalAlignment.Top };
        content.Children.Add(_lines);
        content.Children.Add(_overlay);

        _scroller = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = content,
        };

        _root = new Grid { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(1, 0, 0, 0)) };
        _root.Children.Add(_scroller);

        // No custom `ControlTemplate` — `ContentControl`'s own default template already does
        // exactly "show `Content`", which is all this needs. An earlier version of this
        // constructor built one via `XamlReader.Load` at runtime for no real benefit; removed
        // rather than kept, since runtime XAML parsing is one more thing to go wrong for a
        // control that's specifically trying to avoid this environment's XAML-compiler crash
        // risk (see the class remarks) in the first place.
        Content = _root;

        SizeChanged += (_, _) => Render();
        GotFocus += (_, _) => { _caretVisual.Visibility = Visibility.Visible; PositionCaret(); };
        LostFocus += (_, _) => _caretVisual.Visibility = Visibility.Collapsed;
        KeyDown += OnKeyDown;
        CharacterReceived += OnCharacterReceived;
        PointerPressed += OnBackgroundPointerPressed;
    }

    private Windows.UI.Color DefaultForegroundColor()
    {
        var isLight = ActualTheme == ElementTheme.Light;
        return ResolveThemeColor(isLight ? "Light" : "Dark", "TextControlForeground",
            isLight ? Windows.UI.Color.FromArgb(0xE4, 0x00, 0x00, 0x00) : Windows.UI.Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF));
    }

    /// Same defensive walk (and same reasoning) as `MainWindow`'s copy: `Application.Current
    /// .Resources.ThemeDictionaries` is empty here (this app's App.xaml has no
    /// `&lt;ResourceDictionary.ThemeDictionaries&gt;` of its own — the real Light/Dark
    /// dictionaries live inside the merged `XamlControlsResources`, which doesn't bubble its own
    /// ThemeDictionaries up into the parent's), and a throwing lookup that runs inside a
    /// native-callback continuation hard-crashes the whole process instead of surfacing as a
    /// catchable exception. Never throws; falls back to `fallback` on any failure.
    private static Windows.UI.Color ResolveThemeColor(string themeKey, string resourceKey, Windows.UI.Color fallback)
    {
        try
        {
            foreach (var merged in Application.Current.Resources.MergedDictionaries)
            {
                if (merged.ThemeDictionaries.TryGetValue(themeKey, out var dictObj)
                    && dictObj is ResourceDictionary dict
                    && dict.TryGetValue(resourceKey, out var value)
                    && value is SolidColorBrush brush)
                {
                    return brush.Color;
                }
            }
        }
        catch
        {
            // Fall through to `fallback`.
        }
        return fallback;
    }

    // ==================== Rendering ====================

    private void Render()
    {
        _lines.Children.Clear();
        _runs.Clear();
        _caretVisual.Fill = new SolidColorBrush(DefaultForegroundColor());

        var maxWidth = ActualWidth > 0 ? ActualWidth - 8 : 2000;
        var offset = 0;
        var segments = _text.Split('\n');
        for (var segIndex = 0; segIndex < segments.Length; segIndex++)
        {
            var segment = segments[segIndex];
            var segStart = offset;
            var elements = new List<(FrameworkElement Element, int Start, int End, string? ChipId)>();

            var pos = 0;
            foreach (Match chip in FilterReferencePattern.Matches(segment))
            {
                if (chip.Index > pos)
                {
                    AddPlainSpan(elements, segment[pos..chip.Index], segStart + pos);
                }
                var filterId = chip.Groups[1].Value;
                var name = ResolveFilterName?.Invoke(filterId) ?? $"#{filterId}";
                elements.Add((BuildChip(name, filterId), segStart + chip.Index, segStart + chip.Index + chip.Length, filterId));
                pos = chip.Index + chip.Length;
            }
            if (pos < segment.Length)
            {
                AddPlainSpan(elements, segment[pos..], segStart + pos);
            }
            // An empty line (consecutive '\n's, or an empty document) still needs one element so
            // it has a nonzero-height row and something for the caret to anchor to.
            if (elements.Count == 0)
            {
                elements.Add((new TextBlock { Text = "", FontFamily = FontFamily, FontSize = FontSize }, segStart, segStart, null));
            }

            foreach (var (element, start, end, chipId) in elements)
            {
                _runs.Add(new RunInfo(start, end, element, chipId));
            }
            foreach (var visualLine in WrapIntoLines(elements, maxWidth))
            {
                _lines.Children.Add(visualLine);
            }

            offset += segment.Length + 1; // +1 for the '\n' consumed between segments
        }

        // Not a synchronous UpdateLayout() call here: Render() can itself run from inside a
        // layout pass (e.g. triggered by SizeChanged), and forcing another layout pass
        // re-entrantly while one is already in progress is exactly the kind of thing that throws
        // from deep inside the composition engine, with nowhere safe for that exception to land.
        // Queuing the caret positioning for the next dispatcher tick instead lets the layout this
        // just triggered finish normally first.
        DispatcherQueue.TryEnqueue(PositionCaret);
    }

    private double? _spaceWidth;

    /// The width of one space character in this control's own font, measured rather than
    /// assumed. Confirmed live: a TextBlock whose *entire* content is space characters renders
    /// at (near) zero width in this layout, so a whitespace token can't just be "a TextBlock
    /// with spaces in it" the way every other token is — sandwiching a space between two
    /// ordinary characters and subtracting gives the real per-space advance width instead.
    private double SpaceWidth()
    {
        if (_spaceWidth is { } cached) return cached;
        var withSpace = new TextBlock { Text = "x x", FontFamily = FontFamily, FontSize = FontSize };
        var withoutSpace = new TextBlock { Text = "xx", FontFamily = FontFamily, FontSize = FontSize };
        withSpace.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        withoutSpace.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var width = Math.Max(1, withSpace.DesiredSize.Width - withoutSpace.DesiredSize.Width);
        _spaceWidth = width;
        return width;
    }

    private void AddPlainSpan(List<(FrameworkElement, int, int, string?)> elements, string text, int start)
    {
        var pos = start;
        foreach (Match token in TokenPattern.Matches(text))
        {
            var tokenStart = pos;
            var tokenEnd = pos + token.Length;

            if (string.IsNullOrWhiteSpace(token.Value))
            {
                // A real spacer element, not a whitespace-only TextBlock — see SpaceWidth's own
                // comment for why a text-based approach doesn't hold up here.
                var spacer = new Rectangle
                {
                    Width = SpaceWidth() * token.Length,
                    Height = FontSize,
                    Fill = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0)),
                    VerticalAlignment = VerticalAlignment.Center,
                };
                elements.Add((spacer, tokenStart, tokenEnd, null));
                pos = tokenEnd;
                continue;
            }

            var tb = new TextBlock
            {
                Text = token.Value,
                FontFamily = FontFamily,
                FontSize = FontSize,
                Foreground = new SolidColorBrush(ColorFor(token.Value)),
                VerticalAlignment = VerticalAlignment.Center,
            };
            tb.Tapped += (_, e) =>
            {
                Focus(FocusState.Programmatic);
                var p = e.GetPosition(tb);
                var fraction = tb.ActualWidth > 0 ? Math.Clamp(p.X / tb.ActualWidth, 0, 1) : 0;
                CaretIndex = tokenStart + (int)Math.Round(fraction * (tokenEnd - tokenStart));
                e.Handled = true;
            };
            elements.Add((tb, tokenStart, tokenEnd, null));
            pos = tokenEnd;
        }
    }

    private Windows.UI.Color ColorFor(string token)
    {
        if (JqlStringPattern.IsMatch(token)) return JqlStringColor;
        if (JqlFunctionPattern.IsMatch(token)) return JqlFunctionColor;
        if (JqlKeywordPattern.IsMatch(token)) return JqlKeywordColor;
        if (JqlNumberPattern.IsMatch(token)) return JqlNumberColor;
        return DefaultForegroundColor();
    }

    private Border BuildChip(string name, string filterId)
    {
        var text = new TextBlock
        {
            Text = $"🔗 {name}",
            FontFamily = FontFamily,
            FontSize = FontSize,
            Foreground = new SolidColorBrush(ChipForegroundColor),
        };
        var border = new Border
        {
            Background = new SolidColorBrush(ChipBackgroundColor),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 1, 6, 1),
            Margin = new Thickness(1, 0, 1, 0),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = text,
        };
        border.Tapped += (_, e) =>
        {
            Focus(FocusState.Programmatic);
            var ctrlDown = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            ChipTapped?.Invoke(this, new ChipTappedEventArgs(filterId, ctrlDown));
            e.Handled = true;
        };
        return border;
    }

    /// Greedy width-based packing into visual lines — the closest equivalent to `TextWrapping
    /// ="Wrap"` this setup gets. Every element was already measured to size itself (WinUI does
    /// this automatically once added to a live panel), so this only runs once per full render,
    /// not per frame.
    private static List<StackPanel> WrapIntoLines(List<(FrameworkElement Element, int Start, int End, string? ChipId)> elements, double maxWidth)
    {
        var lines = new List<StackPanel>();
        var current = new StackPanel { Orientation = Orientation.Horizontal };
        double currentWidth = 0;
        foreach (var (element, _, _, _) in elements)
        {
            element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var width = element.DesiredSize.Width;
            if (currentWidth + width > maxWidth && current.Children.Count > 0)
            {
                lines.Add(current);
                current = new StackPanel { Orientation = Orientation.Horizontal };
                currentWidth = 0;
            }
            current.Children.Add(element);
            currentWidth += width;
        }
        lines.Add(current);
        return lines;
    }

    // ==================== Caret & selection ====================

    private void PositionCaret()
    {
        if (_runs.Count == 0) { _caretVisual.Visibility = Visibility.Collapsed; return; }

        var run = _runs.FirstOrDefault(r => r.Start == _caretIndex)
            ?? _runs.FirstOrDefault(r => r.Start < _caretIndex && _caretIndex < r.End)
            ?? _runs.LastOrDefault(r => r.End == _caretIndex)
            ?? _runs[^1];

        Rect bounds;
        try
        {
            bounds = run.Element.TransformToVisual(_overlay).TransformBounds(new Rect(0, 0, run.Element.ActualWidth, run.Element.ActualHeight));
        }
        catch
        {
            return; // Not in the live tree yet (mid-render) — next render pass will reposition.
        }

        var fraction = run.ChipId is null && run.End > run.Start
            ? Math.Clamp((_caretIndex - run.Start) / (double)(run.End - run.Start), 0, 1)
            : (_caretIndex >= run.End ? 1 : 0);

        Canvas.SetLeft(_caretVisual, bounds.X + fraction * bounds.Width);
        Canvas.SetTop(_caretVisual, bounds.Y);
        _caretVisual.Height = bounds.Height > 0 ? bounds.Height : FontSize * 1.4;
    }

    /// Maps a point (in this control's own coordinate space) to the nearest text offset — used
    /// for drag-drop, where the drop lands wherever the pointer happens to be, not on some
    /// specific run's own click handler. Token-granularity, same as click placement.
    public int HitTestOffset(Point point)
    {
        foreach (var run in _runs)
        {
            Rect bounds;
            try { bounds = run.Element.TransformToVisual(this).TransformBounds(new Rect(0, 0, run.Element.ActualWidth, run.Element.ActualHeight)); }
            catch { continue; }
            if (point.Y < bounds.Y || point.Y > bounds.Y + bounds.Height) continue;
            if (point.X < bounds.X) return run.Start;
            if (point.X <= bounds.X + bounds.Width)
            {
                if (run.ChipId is not null) return point.X < bounds.X + bounds.Width / 2 ? run.Start : run.End;
                var fraction = bounds.Width > 0 ? (point.X - bounds.X) / bounds.Width : 0;
                return run.Start + (int)Math.Round(fraction * (run.End - run.Start));
            }
        }
        return _text.Length;
    }

    private void OnBackgroundPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        // Only fires when the click didn't land on a run's own Tapped handler (e.g. the padding
        // around/between lines) — falls back to nearest-offset placement there too.
        Focus(FocusState.Programmatic);
        var point = e.GetCurrentPoint(this).Position;
        CaretIndex = HitTestOffset(point);
    }

    // ==================== Keyboard input ====================

    private (int Start, int Length) SelectionRange()
    {
        if (_selectionAnchor is not { } anchor) return (_caretIndex, 0);
        var start = Math.Min(anchor, _caretIndex);
        return (start, Math.Abs(anchor - _caretIndex));
    }

    private void ReplaceSelection(string with)
    {
        var (start, length) = SelectionRange();
        var newText = _text[..start] + with + _text[(start + length)..];
        _selectionAnchor = null;
        _caretIndex = start + with.Length;
        Text = newText;
    }

    private async void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Handled) return; // MainWindow's PreviewKeyDown (Ctrl+Enter/Escape/suggestions) already claimed it.
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        switch (e.Key)
        {
            case VirtualKey.Left:
                e.Handled = true;
                MoveCaret(-1, shift);
                return;
            case VirtualKey.Right:
                e.Handled = true;
                MoveCaret(1, shift);
                return;
            case VirtualKey.Home:
                e.Handled = true;
                MoveCaretTo(LineStart(_caretIndex), shift);
                return;
            case VirtualKey.End:
                e.Handled = true;
                MoveCaretTo(LineEnd(_caretIndex), shift);
                return;
            case VirtualKey.Back:
                e.Handled = true;
                if (SelectionRange().Length > 0) ReplaceSelection("");
                else if (_caretIndex > 0) { _caretIndex--; Text = _text.Remove(_caretIndex, 1); }
                return;
            case VirtualKey.Delete:
                e.Handled = true;
                if (SelectionRange().Length > 0) ReplaceSelection("");
                else if (_caretIndex < _text.Length) Text = _text.Remove(_caretIndex, 1);
                return;
            case VirtualKey.Enter:
                e.Handled = true;
                ReplaceSelection("\n");
                return;
            case VirtualKey.A when ctrl:
                e.Handled = true;
                _selectionAnchor = 0;
                _caretIndex = _text.Length;
                PositionCaret();
                return;
            case VirtualKey.C when ctrl:
                e.Handled = true;
                CopySelection();
                return;
            case VirtualKey.X when ctrl:
                e.Handled = true;
                CopySelection();
                ReplaceSelection("");
                return;
            case VirtualKey.V when ctrl:
                e.Handled = true;
                await PasteAsync();
                return;
        }
    }

    private void MoveCaret(int delta, bool extendSelection)
    {
        if (!extendSelection && _selectionAnchor is not null)
        {
            var (start, length) = SelectionRange();
            _caretIndex = delta < 0 ? start : start + length;
            _selectionAnchor = null;
        }
        else
        {
            if (extendSelection) _selectionAnchor ??= _caretIndex;
            _caretIndex = Math.Clamp(_caretIndex + delta, 0, _text.Length);
        }
        PositionCaret();
    }

    private void MoveCaretTo(int index, bool extendSelection)
    {
        if (extendSelection) _selectionAnchor ??= _caretIndex;
        else _selectionAnchor = null;
        _caretIndex = Math.Clamp(index, 0, _text.Length);
        PositionCaret();
    }

    private int LineStart(int at)
    {
        var i = _text.LastIndexOf('\n', Math.Max(0, at - 1), at);
        return i < 0 ? 0 : i + 1;
    }

    private int LineEnd(int at)
    {
        var i = _text.IndexOf('\n', at);
        return i < 0 ? _text.Length : i;
    }

    private void CopySelection()
    {
        var (start, length) = SelectionRange();
        if (length == 0) return;
        var package = new DataPackage();
        package.SetText(_text.Substring(start, length));
        Clipboard.SetContent(package);
    }

    private async Task PasteAsync()
    {
        var view = Clipboard.GetContent();
        if (!view.Contains(StandardDataFormats.Text)) return;
        var pasted = await view.GetTextAsync();
        ReplaceSelection(pasted);
    }

    private void OnCharacterReceived(UIElement sender, CharacterReceivedRoutedEventArgs e)
    {
        // Control characters (backspace, enter, etc.) arrive here too on some layouts, but
        // they're already fully handled by OnKeyDown — inserting them literally would double up.
        if (char.IsControl(e.Character)) return;
        e.Handled = true;
        ReplaceSelection(e.Character.ToString());
    }
}

using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using SwiraWin.Native;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Text;

namespace SwiraWin;

/// One row in the sidebar's flattened rendering of Favourites + the filter tree
/// (CLIENT-SPEC.md §2). WinUI's `TreeView` wants either XAML-declared hierarchy or a
/// self-referencing `ItemTemplate`; a flattened list keyed by `Path` is the simpler native
/// primitive and is what makes "each branch's expanded state persists across restarts, keyed by
/// its full path" (§2.2) straightforward — the key already exists, nothing DOM/index-shaped to
/// launder it through.
public sealed class SidebarRow
{
    public required string DisplayName { get; init; }
    public required string Path { get; init; }
    public string? FilterId { get; init; }
    public bool IsGroup { get; init; }
    public bool IsSectionHeader { get; init; }
    public bool HasChildren { get; init; }
    public bool IsExpanded { get; init; }
    public int Depth { get; init; }

    public bool IsSelectable => !IsGroup && !IsSectionHeader;
    public Thickness IndentThickness => new(12 + Depth * 18, 6, 8, 6);
    public FontWeight FontWeight => IsSectionHeader
        ? Microsoft.UI.Text.FontWeights.Bold
        : Microsoft.UI.Text.FontWeights.Normal;
    public double Opacity => IsSectionHeader ? 0.55 : (IsGroup ? 0.85 : 1.0);
    // The favourite glyph used to be a plain Unicode star emoji, which has no glyph in the
    // Segoe MDL2 Assets icon font this TextBlock renders with — it fell back to a tofu box
    // (a hollow square) instead of a star. Using MDL2's own filled-star codepoint fixes that.
    public string Glyph => IsSectionHeader ? ""
        : IsGroup ? (IsExpanded ? "" : "")
        : FilterId != null && DisplayNameIsFavourite ? "" : "";
    public bool DisplayNameIsFavourite { get; init; }
}

/// One editable cell in the table view's dynamic, configurable column set (§3.1). Carries enough
/// to commit an edit (`IssueKey`/`FieldId`) alongside what's shown (`Text`).
public sealed class CellValue
{
    public string Text { get; set; } = "";
    public string FieldId { get; set; } = "";
    public string IssueKey { get; set; } = "";
    // Set when this field's value is (or contains) a reference to another issue — e.g. parent,
    // epic link (§3.1: "MUST render its issue key as a clickable link... uniformly to whatever
    // field happens to carry the reference"). Only single-reference fields resolve to a link
    // today; a field holding several references (subtasks, issue links) still renders as plain
    // text — see ResolveCellLink.
    public string? LinkUrl { get; set; }
    public bool IsLink => LinkUrl is not null;
    // Null (unset) for a plain cell — inherits the row's normal text color. Set to the accent
    // color for a cell whose value references another issue (§3.1), so it reads as a link
    // without needing a second, sibling-toggled template (see ResolveCellLink's comment on why
    // that's avoided here).
    public Brush? TextBrush { get; set; }
}

public sealed class IssueRow
{
    public required string Key { get; init; }
    // Fixed convenience fields — used by split view's card format (§3.2), which is independent
    // of the table's configurable columns.
    public string Summary { get; init; } = "";
    public string Status { get; init; } = "";
    public string Priority { get; init; } = "";
    public string Assignee { get; init; } = "";
    public string Updated { get; init; } = "";
    public string BrowseUrl { get; init; } = "";
    // Table view only: one entry per currently-configured column, same order as ColumnLabels.
    public List<CellValue> Cells { get; init; } = [];

    // Group headers (§3.1) are synthetic rows mixed into the same flat list, rather than
    // ListView.GroupStyle — see the XAML template comments for why. Both item templates show
    // one of two sibling elements depending on which kind a given row is.
    public bool IsGroupHeader { get; init; }
    public string GroupHeaderText { get; init; } = "";
}

/// One row in the Columns flyout's field picker.
public sealed class FieldPickerItem
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
}


public sealed partial class MainWindow : Window
{
    private readonly HashSet<string> _expandedPaths = SidebarState.LoadExpandedPaths();
    // Bound to SidebarList.ItemsSource exactly once, in the constructor, and never reassigned —
    // see ToggleGroup/RebuildSidebarRows for why (avoids the full-list flicker on every
    // expand/collapse click).
    private readonly ObservableCollection<SidebarRow> _sidebarRows = [];
    private SidebarDto? _sidebar;
    private FilterDto? _selectedFilter;
    private bool _splitView;
    private bool _webViewReady;
    private List<ColumnRefDto> _columns = [];
    private List<FieldRefDto>? _allFields;
    private string _sortField = "updated";
    private bool _sortDescending = true;
    private string? _groupField;
    private List<IssueDto> _lastIssues = [];
    private List<IssueRow> _lastRows = [];

    public ObservableCollection<string> ColumnLabels { get; } = [];

    public MainWindow()
    {
        InitializeComponent();
        Title = "Swira";
        // Mica gives the window the same translucent, layered look every other native Windows
        // app has by default — without it a plain WinUI window reads as flat/unstyled.
        if (Microsoft.UI.Composition.SystemBackdrops.MicaController.IsSupported())
        {
            SystemBackdrop = new MicaBackdrop { Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.Base };
        }
        // A default WinUI window keeps the classic solid-color Win10-style title bar, flush
        // against the sidebar/content below it with no visual separation — the giveaway that
        // reads as "unstyled" next to a Win11 app like Settings or Apple Devices, where the
        // title bar is just more Mica and the actual content sits as a distinct, inset, rounded
        // card beneath it. Extending content into the title bar and pairing it with the rounded
        // "AppCard" panel in XAML (see MainWindow.xaml) reproduces that same layering.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        SidebarList.ItemsSource = _sidebarRows;
        QueryTextBox.ResolveFilterName = id => FindFilter(id)?.Name;
        QueryTextBox.TextChanged += QueryTextBox_TextChanged;
        QueryTextBox.ChipTapped += QueryTextBox_ChipTapped;
        Activated += MainWindow_Activated;

        // Light/Dark/System theme override, tucked into the window's own classic system menu
        // (title-bar right-click / Alt+Space) rather than an always-visible toolbar control —
        // it's rarely needed, so it shouldn't compete for space with things that are.
        _theme = ThemeState.Load();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _systemMenu = new SystemMenu(hwnd, _theme, theme => ApplyTheme(theme));
        ApplyTheme(_theme, persist: false);
    }

    private AppTheme _theme;
    private SystemMenu? _systemMenu;

    /// Applies the chosen theme to the window content and, once it exists, the embedded
    /// WebView2 (§ split view — see `NavigateIssuePageAsync`'s `PreferredColorScheme` note).
    /// `persist: false` is only for the constructor's initial apply, where saving back what was
    /// just loaded would be a pointless disk write.
    private void ApplyTheme(AppTheme theme, bool persist = true)
    {
        _theme = theme;
        RootGrid.RequestedTheme = theme switch
        {
            AppTheme.Light => ElementTheme.Light,
            AppTheme.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        _systemMenu?.UpdateCheckmark(theme);
        if (persist) ThemeState.Save(theme);
        if (_webViewReady)
        {
            IssueWebView.CoreWebView2.Profile.PreferredColorScheme = RootGrid.ActualTheme == ElementTheme.Dark
                ? CoreWebView2PreferredColorScheme.Dark
                : CoreWebView2PreferredColorScheme.Light;
        }
        // Already-built CellValue rows were painted with whatever DefaultCellBrush resolved to
        // at load time — plain data objects, not live theme-reactive bindings, so a table already
        // on screen needs a genuine reload to pick up the new theme's color, not just a repaint.
        if (persist && _selectedFilter is not null) _ = LoadIssuesAsync(_selectedFilter.Id);
        // Same story for the query editor's syntax-highlight colors, if it's open — JqlEditor
        // only recomputes them on a Text/size change, not on a theme change by itself.
        if (QueryPanel.Visibility == Visibility.Visible) QueryTextBox.RefreshTheme();
    }

    private bool _started;
    private void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (_started) return;
        _started = true;
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        if (!SwiraCoreBridge.Configure(out var error))
        {
            ShowError(error ?? "Not configured. Set JIRA_URL, JIRA_EMAIL, and JIRA_API_TOKEN.");
            return;
        }
        await LoadSidebarAsync(fresh: false);
    }

    private void ShowError(string message)
    {
        ErrorBanner.Message = message;
        ErrorBanner.IsOpen = true;
    }

    /// §3.4: data served from cache is labelled with its age, and stale data is visually
    /// distinct — never presented as current.
    private void UpdateFreshness(MetaDto? meta)
    {
        if (meta is null) { FreshnessText.Text = ""; return; }
        if (meta.Origin == "network" && !meta.IsStale)
        {
            FreshnessText.Text = "";
            return;
        }
        var age = meta.StoredAt is { } storedAt ? $"as of {storedAt.ToLocalTime():t}" : "cached";
        FreshnessText.Text = meta.IsStale ? $"⚠ stale — {age}" : age;
        FreshnessText.Foreground = meta.IsStale
            ? (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"]
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    }

    // ==================== Sidebar ====================

    private async Task LoadSidebarAsync(bool fresh)
    {
        try
        {
            var json = await SwiraCoreBridge.GetSidebarAsync(fresh);
            _sidebar = Wire.Parse<SidebarDto>(json);
            ErrorBanner.IsOpen = false;
            RebuildSidebarRows();
            UpdateFreshness(_sidebar.Meta);
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
        }
    }

    /// A full reload: only used when the underlying data actually changed (initial load,
    /// Refresh). `SidebarList.ItemsSource` is bound to `_sidebarRows` once and never reassigned —
    /// clearing and refilling the same collection lets the ListView diff and animate normally
    /// instead of doing a hard reset.
    private void RebuildSidebarRows()
    {
        if (_sidebar is null) return;
        var rows = new List<SidebarRow>
        {
            new() { DisplayName = "FAVOURITES", Path = "\0favourites", IsSectionHeader = true },
        };
        foreach (var filter in _sidebar.Favourites.OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase))
        {
            rows.Add(new SidebarRow
            {
                DisplayName = filter.Name,
                Path = "\0fav:" + filter.Id,
                FilterId = filter.Id,
                DisplayNameIsFavourite = true,
            });
        }
        rows.Add(new SidebarRow { DisplayName = "FILTERS", Path = "\0filters", IsSectionHeader = true });
        foreach (var node in _sidebar.Tree)
        {
            AppendNode(node, depth: 0, rows);
        }
        _sidebarRows.Clear();
        foreach (var row in rows) _sidebarRows.Add(row);
    }

    private void AppendNode(NodeDto node, int depth, List<SidebarRow> rows)
    {
        var isGroup = node.Filter is null;
        var expanded = !isGroup || _expandedPaths.Contains(node.Path);
        rows.Add(new SidebarRow
        {
            DisplayName = node.Name,
            Path = node.Path,
            FilterId = node.Filter?.Id,
            IsGroup = isGroup,
            HasChildren = node.Children.Count > 0,
            IsExpanded = expanded,
            Depth = depth,
        });
        if (node.Children.Count > 0 && expanded)
        {
            foreach (var child in node.Children)
            {
                AppendNode(child, depth + 1, rows);
            }
        }
    }

    /// Expanding/collapsing a branch touches only that branch's own row (to flip its glyph) and
    /// inserts/removes exactly its descendant rows — never a full `ItemsSource` reset, which is
    /// what was producing the "whole tree redraws and jumps" flicker on every click.
    private void ToggleGroup(SidebarRow row)
    {
        var index = _sidebarRows.IndexOf(row);
        if (index < 0) return;

        var expanding = !_expandedPaths.Contains(row.Path);
        if (expanding) _expandedPaths.Add(row.Path); else _expandedPaths.Remove(row.Path);
        SidebarState.SaveExpandedPaths(_expandedPaths);

        _sidebarRows[index] = new SidebarRow
        {
            DisplayName = row.DisplayName,
            Path = row.Path,
            FilterId = row.FilterId,
            IsGroup = row.IsGroup,
            HasChildren = row.HasChildren,
            IsExpanded = expanding,
            Depth = row.Depth,
            DisplayNameIsFavourite = row.DisplayNameIsFavourite,
        };

        if (expanding)
        {
            var node = FindNode(row.Path);
            if (node is null) return;
            var children = new List<SidebarRow>();
            foreach (var child in node.Children) AppendNode(child, row.Depth + 1, children);
            for (var i = 0; i < children.Count; i++) _sidebarRows.Insert(index + 1 + i, children[i]);
        }
        else
        {
            var removeAt = index + 1;
            var count = 0;
            while (removeAt + count < _sidebarRows.Count && _sidebarRows[removeAt + count].Depth > row.Depth) count++;
            for (var i = 0; i < count; i++) _sidebarRows.RemoveAt(removeAt);
        }
    }

    private NodeDto? FindNode(string path)
    {
        if (_sidebar is null) return null;
        NodeDto? Search(IEnumerable<NodeDto> nodes)
        {
            foreach (var node in nodes)
            {
                if (node.Path == path) return node;
                var found = Search(node.Children);
                if (found is not null) return found;
            }
            return null;
        }
        return Search(_sidebar.Tree);
    }

    private void SidebarList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SidebarList.SelectedItem is not SidebarRow row) return;

        if (row.IsGroup)
        {
            ToggleGroup(row);
            return;
        }
        if (row.FilterId is null) return;

        // Switching filters closes any open query editor (§2.4) — it belongs to the filter it
        // was opened for.
        QueryPanel.Visibility = Visibility.Collapsed;
        _ = SelectFilterAsync(row.FilterId);
    }

    private async Task SelectFilterAsync(string filterId)
    {
        var filter = FindFilter(filterId);
        _selectedFilter = filter;
        FilterTitle.Text = filter?.Name ?? filterId;
        EditQueryButton.IsEnabled = true;
        ColumnsButton.IsEnabled = true;
        RefreshButton.IsEnabled = true;
        SortFieldCombo.IsEnabled = true;
        SortDirButton.IsEnabled = true;
        GroupFieldCombo.IsEnabled = true;
        await EnsureSortGroupFieldsLoadedAsync();
        ClearIssuePage();
        await LoadIssuesAsync(filterId);
    }

    /// Populates the Sort/Group field pickers once, lazily — same field list `Columns` uses, via
    /// `ReferenceService.fields()`.
    private async Task EnsureSortGroupFieldsLoadedAsync()
    {
        if (_allFields is not null) return;
        try
        {
            _allFields = Wire.Parse<List<FieldRefDto>>(await SwiraCoreBridge.GetFieldsAsync());
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
            return;
        }
        var sorted = _allFields.OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToList();
        SortFieldCombo.ItemsSource = sorted;
        SortFieldCombo.SelectedItem = sorted.FirstOrDefault(f => f.Id == _sortField);
        GroupFieldCombo.ItemsSource = new List<FieldRefDto> { new() { Id = "", Name = "None" } }.Concat(sorted).ToList();
        GroupFieldCombo.SelectedIndex = 0;
    }

    private FilterDto? FindFilter(string id)
    {
        if (_sidebar is null) return null;
        var fromFavourites = _sidebar.Favourites.FirstOrDefault(f => f.Id == id);
        if (fromFavourites is not null) return fromFavourites;
        FilterDto? Search(IEnumerable<NodeDto> nodes)
        {
            foreach (var node in nodes)
            {
                if (node.Filter?.Id == id) return node.Filter;
                var found = Search(node.Children);
                if (found is not null) return found;
            }
            return null;
        }
        return Search(_sidebar.Tree);
    }

    // ==================== Table view ====================

    private async Task LoadIssuesAsync(string filterId)
    {
        try
        {
            // Default sort: updated, descending (§3.1) — SwiraCoreBridge folds this into the
            // request as `filter = <id> ORDER BY <field> <dir>`; it's never written back to the
            // stored filter as a side effect of merely sorting.
            var json = await SwiraCoreBridge.GetFilterIssuesAsync(filterId, _sortField, _sortDescending, limit: 50, pageToken: null);
            var issues = Wire.Parse<IssuesDto>(json);
            _columns = issues.Columns;
            ColumnLabels.Clear();
            foreach (var column in _columns) ColumnLabels.Add(column.Label);

            _lastIssues = issues.Issues;
            _lastRows = issues.Issues.Select(i => new IssueRow
            {
                Key = i.Key,
                Summary = i.Summary ?? "",
                Status = i.Status ?? "",
                Priority = i.Priority ?? "",
                Assignee = i.Assignee ?? "",
                Updated = i.Updated?.ToLocalTime().ToString("g") ?? "",
                BrowseUrl = i.BrowseUrl,
                Cells = _columns.Select(c =>
                {
                    var link = ResolveCellLink(i, c.Value);
                    return new CellValue
                    {
                        FieldId = c.Value,
                        IssueKey = i.Key,
                        Text = ResolveCellText(i, c.Value),
                        LinkUrl = link,
                        TextBrush = link is null ? DefaultCellBrush : LinkCellBrush,
                    };
                }).ToList(),
            }).ToList();
            ApplyGrouping();
            ErrorBanner.IsOpen = false;
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
        }
    }

    /// Buckets the currently loaded page by `_groupField`'s value and inserts a header row per
    /// bucket, in both view modes (§3.1) — client-side over the already-loaded page, since Jira's
    /// search API has no `GROUP BY`. `_lastIssues`/`_lastRows` stay in the same order/count so
    /// they can be paired by index for the group key, independent of which columns are shown.
    ///
    /// Group headers are synthetic `IssueRow`s (`IsGroupHeader = true`) spliced into the same
    /// flat list, not `ListView.GroupStyle`/`CollectionViewSource` grouping — this dev
    /// environment's XAML compiler (Windows App SDK 1.6, no Visual Studio) crashes outright on a
    /// `GroupStyle.HeaderTemplate` block with no usable diagnostic, so this sidesteps it entirely.
    private void ApplyGrouping()
    {
        // Table and split share the same loaded page and the same sort/group toolbar state
        // (§3.2).
        if (string.IsNullOrEmpty(_groupField))
        {
            IssuesList.ItemsSource = _lastRows;
            SplitIssuesList.ItemsSource = _lastRows;
            return;
        }
        var groups = _lastRows
            .Select((row, i) => (Row: row, Key: ResolveCellText(_lastIssues[i], _groupField!)))
            .GroupBy(pair => pair.Key.Length == 0 ? "(empty)" : pair.Key, pair => pair.Row)
            .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase);

        var flattened = new List<IssueRow>();
        foreach (var group in groups)
        {
            flattened.Add(new IssueRow { Key = "", IsGroupHeader = true, GroupHeaderText = $"{group.Key} ({group.Count()})" });
            flattened.AddRange(group);
        }
        IssuesList.ItemsSource = flattened;
        SplitIssuesList.ItemsSource = flattened;
    }

    /// The text a table cell shows for one (issue, fieldId) pair. Known system fields go through
    /// `IssueDto`'s typed convenience properties; anything else — including custom fields — comes
    /// from the untyped `fields` dictionary, best-effort stringified (§3.1: "complex custom
    /// fields render read-only until a later revision" — this is that read-only rendering).
    private static string ResolveCellText(IssueDto issue, string fieldId) => fieldId switch
    {
        "summary" => issue.Summary ?? "",
        "status" => issue.Status ?? "",
        "issuetype" => issue.IssueType ?? "",
        "priority" => issue.Priority ?? "",
        "assignee" => issue.Assignee ?? "",
        "updated" => issue.Updated?.ToLocalTime().ToString("g") ?? "",
        _ => issue.Fields.TryGetValue(fieldId, out var value) ? StringifyField(value) : "",
    };

    private static readonly Regex IssueKeyPattern = new(@"^[A-Z][A-Z0-9_]*-\d+$", RegexOptions.Compiled);

    /// A browse URL for `fieldId`'s value, if that value **is** a reference to another issue —
    /// `{ "key": "PROJ-1", ... }` (parent, most link shapes) or a bare `"PROJ-1"` string (some
    /// epic-link schemas) — not hardcoded to specific field ids (§3.1). A field holding several
    /// references (an array — subtasks, issuelinks) isn't linked here: rendering each key inside
    /// one cell as its own clickable segment would need per-item templates, which this project's
    /// XAML compiler can't build reliably (see the `ListView.GroupStyle`/`DataTemplateSelector`
    /// note in CLAUDE.md) — tracked as a known gap, not a silent field-id allowlist.
    private static string? ResolveCellLink(IssueDto issue, string fieldId)
    {
        if (fieldId is "summary" or "status" or "priority" or "assignee" or "updated" or "issuetype") return null;
        if (!issue.Fields.TryGetValue(fieldId, out var value)) return null;

        string? key = null;
        if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty("key", out var keyProp)
            && keyProp.ValueKind == JsonValueKind.String)
        {
            key = keyProp.GetString();
        }
        else if (value.ValueKind == JsonValueKind.String)
        {
            key = value.GetString();
        }
        if (key is null || !IssueKeyPattern.IsMatch(key)) return null;

        // Derived from the current issue's own BrowseUrl ("{base}/browse/{ownKey}") rather than a
        // separate site-base field — the ABI doesn't hand one back separately.
        var suffix = "/browse/" + issue.Key;
        if (!issue.BrowseUrl.EndsWith(suffix, StringComparison.Ordinal)) return null;
        var siteBase = issue.BrowseUrl[..^suffix.Length];
        return $"{siteBase}/browse/{key}";
    }

    private static string StringifyField(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString() ?? "",
        JsonValueKind.Number => value.ToString(),
        JsonValueKind.True => "true",
        JsonValueKind.False => "false",
        JsonValueKind.Null or JsonValueKind.Undefined => "",
        JsonValueKind.Object => value.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? ""
            : value.TryGetProperty("name", out var n) ? n.GetString() ?? ""
            : value.TryGetProperty("value", out var v) ? v.GetString() ?? ""
            : "…",
        JsonValueKind.Array => string.Join(", ", value.EnumerateArray().Select(StringifyField)),
        _ => "",
    };

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
        await LoadSidebarAsync(fresh: true);
    }

    // Key column: always a clickable link to the issue's real Jira page (§3.1), regardless of
    // view mode — opens in the system browser, since table view has no embedded page pane
    // (that's what split view's right pane is for).
    private async void IssueLink_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string url } && !string.IsNullOrEmpty(url))
        {
            await Launcher.LaunchUriAsync(new Uri(url));
        }
    }

    /// A table cell whose value references another issue (§3.1) opens that issue's page on a
    /// single click — same as `IssueLink_Click`, just wired to `TextBlock.Tapped` instead of
    /// `Button.Click` since a plain cell isn't a button. No-ops when `Tag` (`LinkUrl`) is null.
    private async void CellLink_Tapped(object sender, TappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string url } && !string.IsNullOrEmpty(url))
        {
            await Launcher.LaunchUriAsync(new Uri(url));
        }
    }

    // ==================== Cell editing (§3.1) ====================

    // Basic field types are editable in place: text goes through the XAML-declared flyout below;
    // priority/assignee/status/fix-versions get a purpose-built picker each, dispatched by
    // fieldId, matching how the web client treats these same field kinds differently (a plain
    // text input would let you type a priority name that doesn't exist, an assignee id no one
    // has, etc.).
    private static readonly Brush LinkCellBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0x60, 0xA5, 0xFA));

    // A plain (non-link) cell's TextBlock binds Foreground to this via x:Bind — it must never be
    // null. x:Bind assigns a null Brush straight through to the dependency property instead of
    // leaving the property at its inherited/theme default, so a null here doesn't fall back to
    // normal text color, it paints nothing: the text is genuinely present in the tree (which is
    // why a UI-Automation read of its Text property looks completely fine) but invisible on
    // screen. Only the Key column escaped this, because it's a separate HyperlinkButton with its
    // own default foreground, not this shared template.
    // Deliberately NOT cached (a prior version of this cached the result in a `static` field and
    // regressed exactly this bug: switching theme via the system menu left already-built rows,
    // and every row built afterward, painted with the stale pre-switch color, right back to
    // invisible-against-background).
    private Brush DefaultCellBrush
    {
        get
        {
            var isLight = RootGrid.ActualTheme == ElementTheme.Light;
            var fallback = isLight
                ? Windows.UI.Color.FromArgb(0xE4, 0x00, 0x00, 0x00)
                : Windows.UI.Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF);
            return new SolidColorBrush(ResolveThemeColor(isLight ? "Light" : "Dark", "TextFillColorPrimaryBrush", fallback));
        }
    }

    /// Looks up a theme-specific color by walking each *merged* resource dictionary's own
    /// `ThemeDictionaries` for `resourceKey` under `themeKey` ("Light"/"Dark"). Deliberately not
    /// `Application.Current.Resources.ThemeDictionaries[themeKey]` directly — that collection is
    /// only populated from a `&lt;ResourceDictionary.ThemeDictionaries&gt;` block declared
    /// directly in App.xaml's own dictionary, which this app doesn't have; the real Light/Dark
    /// dictionaries live *inside* the merged `XamlControlsResources` dictionary, and merging
    /// doesn't bubble a child dictionary's own ThemeDictionaries up into the parent's collection.
    /// A bare `ThemeDictionaries[themeKey]` there throws `KeyNotFoundException` — confirmed by
    /// reproducing an actual crash from it: the exception unwound through
    /// `SwiraCoreBridge`'s `UnmanagedCallersOnly` reply thunk (this runs inside a
    /// `LoadIssuesAsync` continuation resumed from a native callback), and an exception escaping
    /// an `UnmanagedCallersOnly` method makes the .NET runtime hard-`FailFast` the whole process
    /// instead of surfacing an ordinary catchable exception — observed as Windows Error Reporting
    /// faulting `Microsoft.UI.Xaml.dll` with `0xC000027B`, the same code CLAUDE.md documents for
    /// a missing `resources.pri` (a red herring here — the herring is why it took a clean rebuild
    /// to rule that explanation out). This method therefore never throws, full stop: any failure
    /// — an unexpected shape, a missing key, anything — falls back to `fallback` instead.
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
    private Flyout? _openCellFlyout;
    private List<PriorityRefDto>? _priorities;

    private void Cell_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: CellValue cell } element) return;
        // A reference-to-another-issue cell (§3.1) is click-to-navigate only — editing it as raw
        // text wouldn't be meaningful anyway, and would fight the single-click Tapped handler
        // that opens the referenced issue (both fire on the first click of a double-click).
        if (cell.IsLink) return;
        switch (cell.FieldId)
        {
            case "priority": _ = OpenPriorityEditorAsync(element, cell); break;
            case "assignee": OpenAssigneeEditor(element, cell); break;
            case "status": _ = OpenStatusEditorAsync(element, cell); break;
            case "fixVersions": _ = OpenFixVersionsEditorAsync(element, cell); break;
            default: OpenTextEditor(element, cell); break;
        }
    }

    /// The plain-text path (default field types, and `labels` as a comma-separated list) — the
    /// only one using the flyout declared in XAML, since it's just a `TextBox`.
    private void OpenTextEditor(FrameworkElement element, CellValue cell)
    {
        var flyout = (Flyout)FlyoutBase.GetAttachedFlyout(element);
        var panel = (StackPanel)flyout.Content;
        var box = (TextBox)panel.Children[0];
        box.Text = cell.Text;
        box.Tag = cell;
        _openCellFlyout = flyout;
        flyout.ShowAt(element);
        box.Focus(FocusState.Programmatic);
        box.SelectAll();
    }

    private async void CellEditBox_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        var box = (TextBox)sender;
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            _openCellFlyout?.Hide();
            return;
        }
        if (e.Key != VirtualKey.Enter || box.Tag is not CellValue cell) return;
        e.Handled = true;
        _openCellFlyout?.Hide();
        try
        {
            if (cell.FieldId == "labels")
            {
                var labels = box.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                await SwiraCoreBridge.SetIssueLabelsAsync(cell.IssueKey, JsonSerializer.Serialize(labels));
            }
            else
            {
                await SwiraCoreBridge.SetIssueTextAsync(cell.IssueKey, cell.FieldId, box.Text);
            }
            if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
        }
    }

    private async Task OpenPriorityEditorAsync(FrameworkElement anchor, CellValue cell)
    {
        try
        {
            _priorities ??= Wire.Parse<List<PriorityRefDto>>(await SwiraCoreBridge.GetPrioritiesAsync());
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
            return;
        }

        var list = new ListView
        {
            ItemsSource = _priorities,
            DisplayMemberPath = nameof(PriorityRefDto.Name),
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 260,
            Width = 180,
        };
        var flyout = new Flyout { Content = list };
        list.SelectionChanged += async (_, _) =>
        {
            if (list.SelectedItem is not PriorityRefDto priority) return;
            flyout.Hide();
            try
            {
                await SwiraCoreBridge.SetIssuePriorityAsync(cell.IssueKey, priority.Id);
                if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
            }
            catch (SwiraNativeException ex)
            {
                ShowError(ex.Message);
            }
        };
        flyout.ShowAt(anchor);
    }

    /// Type-to-filter search-by-name picker (§3.1: "MUST offer a way to change which filter..." —
    /// same spirit here for assignee), plus an explicit Unassign action.
    private void OpenAssigneeEditor(FrameworkElement anchor, CellValue cell)
    {
        var panel = new StackPanel { Spacing = 6, Width = 220 };
        var searchBox = new TextBox { PlaceholderText = "Search people…" };
        var list = new ListView { DisplayMemberPath = nameof(UserRefDto.DisplayName), MaxHeight = 200 };
        var unassign = new Button { Content = "Unassign", HorizontalAlignment = HorizontalAlignment.Stretch };
        panel.Children.Add(searchBox);
        panel.Children.Add(list);
        panel.Children.Add(unassign);
        var flyout = new Flyout { Content = panel };

        async void Commit(string? accountId)
        {
            flyout.Hide();
            try
            {
                await SwiraCoreBridge.SetIssueAssigneeAsync(cell.IssueKey, accountId);
                if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
            }
            catch (SwiraNativeException ex)
            {
                ShowError(ex.Message);
            }
        }

        unassign.Click += (_, _) => Commit(null);
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is UserRefDto user) Commit(user.AccountId);
        };
        searchBox.TextChanged += async (_, _) =>
        {
            try
            {
                list.ItemsSource = Wire.Parse<List<UserRefDto>>(await SwiraCoreBridge.SearchUsersAsync(searchBox.Text));
            }
            catch (SwiraNativeException)
            {
                // A transient search failure isn't worth interrupting typing for.
            }
        };

        flyout.ShowAt(anchor);
        searchBox.Focus(FocusState.Programmatic);
    }

    /// Status isn't a plain field Jira lets you overwrite — it only moves via a workflow
    /// transition (`IssueService.transitions`/`transition`), so this lists the transitions
    /// actually available for this issue right now, not every status that exists.
    private async Task OpenStatusEditorAsync(FrameworkElement anchor, CellValue cell)
    {
        List<TransitionDto> transitions;
        try
        {
            transitions = Wire.Parse<List<TransitionDto>>(await SwiraCoreBridge.GetTransitionsAsync(cell.IssueKey));
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
            return;
        }
        if (transitions.Count == 0)
        {
            ShowError("No transitions available for this issue.");
            return;
        }

        var list = new ListView
        {
            ItemsSource = transitions,
            DisplayMemberPath = nameof(TransitionDto.Name),
            MaxHeight = 240,
            Width = 200,
        };
        var flyout = new Flyout { Content = list };
        list.SelectionChanged += async (_, _) =>
        {
            if (list.SelectedItem is not TransitionDto transition) return;
            flyout.Hide();
            try
            {
                await SwiraCoreBridge.TransitionIssueAsync(cell.IssueKey, transition.Id);
                if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
            }
            catch (SwiraNativeException ex)
            {
                ShowError(ex.Message);
            }
        };
        flyout.ShowAt(anchor);
    }

    /// A multi-select checklist against the issue's project's actual version list (§3.1) — an id
    /// is unambiguous where a typed name could collide across projects. The project key comes
    /// straight from the issue key (`PROJ-123` → `PROJ`), Jira's own convention, rather than a
    /// separate lookup. Pre-selection matches by name against the cell's current display text
    /// (not by id — the table only carries stringified display values, not raw field ids).
    private async Task OpenFixVersionsEditorAsync(FrameworkElement anchor, CellValue cell)
    {
        var dash = cell.IssueKey.LastIndexOf('-');
        var projectKey = dash > 0 ? cell.IssueKey[..dash] : cell.IssueKey;

        List<VersionRefDto> versions;
        try
        {
            versions = Wire.Parse<List<VersionRefDto>>(await SwiraCoreBridge.GetProjectVersionsAsync(projectKey));
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
            return;
        }

        var currentNames = cell.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToHashSet();
        // Already-selected first, so a chosen version can never fall out of view behind a search
        // filter or (if the list were ever capped) a cutoff (§3.1).
        var ordered = versions.OrderByDescending(v => currentNames.Contains(v.Name)).ToList();

        var panel = new StackPanel { Spacing = 4, Width = 240 };
        var searchBox = new TextBox { PlaceholderText = "Search versions…" };
        panel.Children.Add(searchBox);
        var rows = new List<(CheckBox Box, VersionRefDto Version)>();
        foreach (var version in ordered)
        {
            var box = new CheckBox { Content = version.Name, IsChecked = currentNames.Contains(version.Name) };
            rows.Add((box, version));
            panel.Children.Add(box);
        }
        searchBox.TextChanged += (_, _) =>
        {
            var q = searchBox.Text;
            foreach (var (box, version) in rows)
            {
                box.Visibility = box.IsChecked == true || q.Length == 0
                    || version.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                    ? Visibility.Visible : Visibility.Collapsed;
            }
        };
        var apply = new Button { Content = "Apply", HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 8, 0, 0) };
        panel.Children.Add(apply);
        var flyout = new Flyout { Content = new ScrollViewer { Content = panel, MaxHeight = 320 } };

        apply.Click += async (_, _) =>
        {
            flyout.Hide();
            var ids = rows.Where(r => r.Box.IsChecked == true).Select(r => r.Version.Id).ToList();
            try
            {
                await SwiraCoreBridge.SetIssueFixVersionsAsync(cell.IssueKey, JsonSerializer.Serialize(ids));
                if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
            }
            catch (SwiraNativeException ex)
            {
                ShowError(ex.Message);
            }
        };
        flyout.ShowAt(anchor);
    }

    // ==================== Columns (§3.1) ====================
    //
    // Two lists, matching the web client: `_currentColumns` is the ordered, live-edited set
    // (bound directly to CurrentColumnsList — ListView's built-in CanReorderItems drag-reorder
    // writes straight back into this ObservableCollection, no extra plumbing needed), and the
    // search box below filters `_allFields` down to whatever isn't already in `_currentColumns`.

    private readonly ObservableCollection<FieldPickerItem> _currentColumns = [];

    private async void ColumnsButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedFilter is null) return;
        _allFields ??= Wire.Parse<List<FieldRefDto>>(await SwiraCoreBridge.GetFieldsAsync());

        _currentColumns.Clear();
        foreach (var c in _columns)
        {
            var name = _allFields.FirstOrDefault(f => f.Id == c.Value)?.Name ?? c.Label;
            _currentColumns.Add(new FieldPickerItem { Id = c.Value, Name = name });
        }
        CurrentColumnsList.ItemsSource = _currentColumns;

        ColumnsSearchBox.Text = "";
        ColumnsSearchResultsList.ItemsSource = null;
        ColumnsFlyout.ShowAt(ColumnsButton);
    }

    private void RemoveColumn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string fieldId }) return;
        var item = _currentColumns.FirstOrDefault(c => c.Id == fieldId);
        if (item is not null) _currentColumns.Remove(item);
    }

    /// Type-to-filter search (§3.1) over every site field not already a current column —
    /// matches on name or id, case-insensitively, capped the same way the other pickers in this
    /// file cap large lists (see e.g. `OpenFixVersionsEditorAsync`).
    private void ColumnsSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        var query = ColumnsSearchBox.Text.Trim();
        var inUse = _currentColumns.Select(c => c.Id).ToHashSet();
        var candidates = (_allFields ?? []).Where(f => !inUse.Contains(f.Id));
        if (query.Length > 0)
        {
            candidates = candidates.Where(f =>
                f.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                f.Id.Contains(query, StringComparison.OrdinalIgnoreCase));
        }
        ColumnsSearchResultsList.ItemsSource = candidates
            .OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
            .Take(50)
            .Select(f => new FieldPickerItem { Id = f.Id, Name = f.Name })
            .ToList();
    }

    private void ColumnsSearchResult_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not FieldPickerItem field) return;
        if (_currentColumns.Any(c => c.Id == field.Id)) return;
        _currentColumns.Add(field);
        ColumnsSearchBox.Text = "";
        ColumnsSearchBox.Focus(FocusState.Programmatic);
    }

    private async void ApplyColumns_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedFilter is null) return;
        try
        {
            var json = JsonSerializer.Serialize(_currentColumns.Select(c => c.Id));
            await SwiraCoreBridge.SetColumnsAsync(_selectedFilter.Id, json);
            ColumnsFlyout.Hide();
            await LoadIssuesAsync(_selectedFilter.Id);
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
        }
    }

    private async void ResetColumns_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedFilter is null) return;
        try
        {
            await SwiraCoreBridge.ResetColumnsAsync(_selectedFilter.Id);
            ColumnsFlyout.Hide();
            await LoadIssuesAsync(_selectedFilter.Id);
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
        }
    }

    // ==================== Sort / Group (§3.1) ====================

    private async void SortFieldCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SortFieldCombo.SelectedItem is not FieldRefDto field || _selectedFilter is null) return;
        _sortField = field.Id;
        await LoadIssuesAsync(_selectedFilter.Id);
    }

    private async void SortDirButton_Click(object sender, RoutedEventArgs e)
    {
        _sortDescending = !_sortDescending;
        SortDirButton.Content = _sortDescending ? "↓ Desc" : "↑ Asc";
        if (_selectedFilter is not null) await LoadIssuesAsync(_selectedFilter.Id);
    }

    private void GroupFieldCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (GroupFieldCombo.SelectedItem is not FieldRefDto field) return;
        _groupField = field.Id.Length == 0 ? null : field.Id;
        // Client-side only (§3.1: "Jira's search API has no GROUP BY, not a second server-side
        // query") — re-buckets the page already in memory, no reload.
        ApplyGrouping();
    }

    // ==================== View switcher (§3: table view vs. split view) ====================

    private void TableViewButton_Click(object sender, RoutedEventArgs e) => SetViewMode(split: false);
    private void SplitViewButton_Click(object sender, RoutedEventArgs e) => SetViewMode(split: true);

    private void SetViewMode(bool split)
    {
        _splitView = split;
        TableViewButton.IsChecked = !split;
        SplitViewButton.IsChecked = split;
        TableViewGrid.Visibility = split ? Visibility.Collapsed : Visibility.Visible;
        SplitViewGrid.Visibility = split ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void SplitIssuesList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SplitIssuesList.SelectedItem is not IssueRow row || string.IsNullOrEmpty(row.BrowseUrl)) return;
        await NavigateIssuePageAsync(row.BrowseUrl);
    }

    private async Task NavigateIssuePageAsync(string url)
    {
        if (!_webViewReady)
        {
            await IssueWebView.EnsureCoreWebView2Async();
            _webViewReady = true;
            // Jira's own page theme is ultimately the account's Atlassian profile setting, not
            // something a host app can force — but the WebView2 host itself, and any Jira UI that
            // does honor prefers-color-scheme, can at least be told which theme the app is in, so
            // the embedded page isn't jarringly light inside an otherwise dark window.
            var isDark = RootGrid.ActualTheme == ElementTheme.Dark;
            IssueWebView.CoreWebView2.Profile.PreferredColorScheme = isDark
                ? CoreWebView2PreferredColorScheme.Dark
                : CoreWebView2PreferredColorScheme.Light;
        }
        SplitViewPlaceholder.Visibility = Visibility.Collapsed;
        IssueWebView.CoreWebView2.Navigate(url);
    }

    private void ClearIssuePage()
    {
        SplitViewPlaceholder.Visibility = Visibility.Visible;
        if (_webViewReady) IssueWebView.CoreWebView2.Navigate("about:blank");
    }

    // ==================== Query editor (§3.3) ====================
    //
    // `QueryTextBox.Text` is now always plain JQL — `JqlEditor` renders `filter = <id>` clauses
    // as chips itself (resolving names via `ResolveFilterName`), so there's no separate "raw
    // display text with markers" vs "real JQL" distinction to reconcile anymore, and nothing
    // here needs to convert between them.

    // ==================== Multiline JQL formatting (§3.3) ====================
    //
    // Ports the same rules Sources/swira-web/WebUI.swift's formatter uses: break at top-level
    // AND/OR onto their own lines; NOT/IN/NOT IN never break points, always stay glued to their
    // condition; a clause list (top-level conditions, a paren group's conditions, or an IN-list's
    // values) of more than JqlInlineLimit items forces a break one-per-line even if the flat text
    // would still fit the width; ORDER BY always lands on its own line and is never itself split;
    // an already-multiline query (one the user broke by hand) is never reflowed.

    private const int JqlIndentUnit = 2;
    private const int JqlInlineLimit = 3;

    private static readonly Regex TopLevelInPattern = new(@"\b(not\s+)?in\s*$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex OrderByTailPattern = new(@"\s*(\border\s+by\s+.+)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    // \G (not ^) — Match(expr, i) only tells the engine where to *start scanning*; ^ still
    // anchors to true position 0 of the whole string, so with ^ this pattern only ever matched
    // when i == 0 and SplitTopLevelJql silently never split on AND/OR at all. \G anchors to the
    // actual search-start position passed to Match, which is what "a connective right here" needs.
    private static readonly Regex ConnectiveAtPattern = new(@"\G\s*(AND|OR)\s+", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// Splits on top-level `AND`/`OR` — paren- and quote-depth aware, so a connective inside a
    /// nested group or a string literal is never mistaken for one that actually separates
    /// top-level clauses.
    private static (List<string> Parts, List<string> Connectives) SplitTopLevelJql(string expr)
    {
        var parts = new List<string>();
        var connectives = new List<string>();
        var depth = 0;
        char? quote = null;
        var start = 0;
        var i = 0;
        while (i < expr.Length)
        {
            var c = expr[i];
            if (quote is { } q)
            {
                if (c == q) quote = null;
                i++;
                continue;
            }
            if (c is '"' or '\'') { quote = c; i++; continue; }
            if (c == '(') { depth++; i++; continue; }
            if (c == ')') { depth--; i++; continue; }
            if (depth == 0 && char.IsWhiteSpace(c))
            {
                var m = ConnectiveAtPattern.Match(expr, i);
                if (m.Success && m.Index == i)
                {
                    parts.Add(expr[start..i].Trim());
                    connectives.Add(m.Groups[1].Value.ToUpperInvariant());
                    i += m.Length;
                    start = i;
                    continue;
                }
            }
            i++;
        }
        parts.Add(expr[start..].Trim());
        return (parts, connectives);
    }

    private static bool IsParenWrapped(string text)
    {
        text = text.Trim();
        if (text.Length < 2 || text[0] != '(' || text[^1] != ')') return false;
        var depth = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '(') depth++;
            else if (text[i] == ')')
            {
                depth--;
                if (depth == 0 && i != text.Length - 1) return false;
            }
        }
        return depth == 0;
    }

    /// A trailing `(...)` group at the end of `text`, split into what's before it and what's
    /// inside — used to find an `IN (...)`/`NOT IN (...)` clause's value list.
    private static (string Head, string Inner)? TrailingParenGroup(string text)
    {
        text = text.TrimEnd();
        if (text.Length == 0 || text[^1] != ')') return null;
        var depth = 0;
        for (var i = text.Length - 1; i >= 0; i--)
        {
            if (text[i] == ')') depth++;
            else if (text[i] == '(')
            {
                depth--;
                if (depth == 0) return (text[..i].TrimEnd(), text[(i + 1)..^1]);
            }
        }
        return null;
    }

    private static List<string> SplitTopLevelCommaList(string text)
    {
        var items = new List<string>();
        var depth = 0;
        char? quote = null;
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quote is { } q) { if (c == q) quote = null; continue; }
            if (c is '"' or '\'') { quote = c; continue; }
            if (c == '(') depth++;
            else if (c == ')') depth--;
            else if (c == ',' && depth == 0)
            {
                items.Add(text[start..i].Trim());
                start = i + 1;
            }
        }
        items.Add(text[start..].Trim());
        return items;
    }

    /// Width-independent structural check: does any clause list anywhere in `text` — top-level,
    /// inside a paren group, or an IN-list — hold more than `JqlInlineLimit` items? Used to force
    /// a nested group to explode even when the outer level's own item count and flat width would
    /// otherwise say "inline".
    private static bool HasOversizedList(string text)
    {
        var (parts, _) = SplitTopLevelJql(text);
        if (parts.Count > JqlInlineLimit) return true;
        foreach (var part in parts)
        {
            var trimmed = part.Trim();
            if (IsParenWrapped(trimmed) && HasOversizedList(trimmed[1..^1]))
            {
                return true;
            }
            if (TrailingParenGroup(trimmed) is { } trailing && TopLevelInPattern.IsMatch(trailing.Head)
                && SplitTopLevelCommaList(trailing.Inner).Count > JqlInlineLimit)
            {
                return true;
            }
        }
        return false;
    }

    /// Recursively formats `text` into already-indented lines. Top-down: paren-wrapped branch,
    /// multi-part (AND/OR) branch, then a leaf check for a trailing IN-list — each stays inline
    /// if it both fits `columns` and has no oversized list anywhere inside it.
    private static List<string> FormatJqlLines(string text, int indent, int columns)
    {
        text = text.Trim();
        var pad = new string(' ', indent);

        if (IsParenWrapped(text))
        {
            var inner = text[1..^1].Trim();
            var (innerParts, _) = SplitTopLevelJql(inner);
            var fits = innerParts.Count <= JqlInlineLimit && !innerParts.Any(HasOversizedList)
                && pad.Length + text.Length <= columns;
            if (fits) return [pad + text];

            var lines = new List<string> { pad + "(" };
            lines.AddRange(FormatJqlLines(inner, indent + JqlIndentUnit, columns));
            lines.Add(pad + ")");
            return lines;
        }

        var (parts, connectives) = SplitTopLevelJql(text);
        if (parts.Count > 1)
        {
            var fits = parts.Count <= JqlInlineLimit && !parts.Any(HasOversizedList)
                && pad.Length + text.Length <= columns;
            if (fits) return [pad + text];

            var lines = new List<string>();
            for (var i = 0; i < parts.Count; i++)
            {
                var partLines = FormatJqlLines(parts[i], indent, columns);
                if (i > 0) partLines[0] = $"{pad}{connectives[i - 1]} {partLines[0].TrimStart()}";
                lines.AddRange(partLines);
            }
            return lines;
        }

        if (TrailingParenGroup(text) is { } t && TopLevelInPattern.IsMatch(t.Head))
        {
            var values = SplitTopLevelCommaList(t.Inner);
            var inlineText = $"{t.Head} ({string.Join(", ", values)})";
            if (values.Count <= JqlInlineLimit && pad.Length + inlineText.Length <= columns)
            {
                return [pad + inlineText];
            }
            var innerPad = new string(' ', indent + JqlIndentUnit);
            var lines = new List<string> { $"{pad}{t.Head} (" };
            for (var i = 0; i < values.Count; i++)
            {
                lines.Add(innerPad + values[i] + (i < values.Count - 1 ? "," : ""));
            }
            lines.Add(pad + ")");
            return lines;
        }

        return [pad + text];
    }

    private static string FormatJqlIfNeeded(string jql, int columns)
    {
        var orderByMatch = OrderByTailPattern.Match(jql);
        var baseText = (orderByMatch.Success ? jql[..orderByMatch.Index] : jql).Trim();
        var orderBy = orderByMatch.Success ? orderByMatch.Groups[1].Value.Trim() : null;
        if (baseText.Length == 0) return orderBy ?? "";

        var formattedBase = string.Join("\n", FormatJqlLines(baseText, 0, columns));
        var combinedFits = !formattedBase.Contains('\n')
            && (orderBy is null ? formattedBase.Length : formattedBase.Length + 1 + orderBy.Length) <= columns;
        if (combinedFits) return orderBy is null ? formattedBase : $"{formattedBase} {orderBy}";
        return orderBy is null ? formattedBase : $"{formattedBase}\n{orderBy}";
    }

    /// Only ever acts on text with no existing `\n` — never reflows line breaks the user already
    /// chose by hand (§3.3). Returns whether it changed anything.
    private bool MaybeAutoFormatJql()
    {
        var text = QueryTextBox.Text;
        if (text.Contains('\n')) return false;
        var columns = Math.Max(40, (int)(QueryTextBox.ActualWidth / 8));
        var formatted = FormatJqlIfNeeded(text, columns);
        if (formatted == text) return false;
        QueryTextBox.Text = formatted;
        return true;
    }

    /// Space opens the query editor for the selected filter, as a faster path than the toolbar
    /// button (§3.3) — but only when no field anywhere in the window has keyboard focus, so it
    /// never fights ordinary typing (a space inside a text box, a space toggling a checkbox).
    private void RootGrid_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Space || _selectedFilter is null || QueryPanel.Visibility == Visibility.Visible) return;
        var focused = FocusManager.GetFocusedElement(Content.XamlRoot);
        if (focused is TextBox or RichEditBox or JqlEditor or ComboBox or CheckBox or Button or ListViewItem) return;
        e.Handled = true;
        EditQuery_Click(this, new RoutedEventArgs());
    }

    private void EditQuery_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedFilter is null) return;
        QueryTextBox.Text = FoldSortIntoJql(_selectedFilter.Jql ?? "");
        QueryErrors.Text = "";
        QueryPanel.Visibility = Visibility.Visible;
        QueryTextBox.Focus(FocusState.Programmatic);
        MaybeAutoFormatJql();
    }

    /// The active toolbar sort is folded into what the editor shows (§3.1), so "sort, then open
    /// Edit query, then Apply" persists it in one step — nothing is saved until that explicit
    /// Apply, and merely opening the editor never touches the stored filter.
    private string FoldSortIntoJql(string jql)
    {
        var stripped = Regex.Replace(jql, @"\s*\border\s+by\s+.+$", "", RegexOptions.IgnoreCase).TrimEnd();
        var orderBy = $"ORDER BY {_sortField} {(_sortDescending ? "DESC" : "ASC")}";
        return stripped.Length == 0 ? orderBy : $"{stripped} {orderBy}";
    }

    // Debounces UpdateSuggestionsAsync so a suggestion request goes out only once typing pauses,
    // not once per keystroke. Without this, fast typing fired one live SwiraCoreBridge network
    // call per character with nothing to cancel or supersede the previous one — a growing pile of
    // in-flight requests that could still resolve (and repaint the suggestion list) in any order,
    // and since every core call is serialized through the same JiraClient actor, a stack of them
    // is the most plausible mechanism behind reports of the app "freezing" while typing in the
    // query editor: unrelated core-backed UI actions queue up behind the same actor until the
    // backlog drains.
    private CancellationTokenSource? _suggestionsDebounce;

    private void QueryTextBox_TextChanged(object? sender, EventArgs e)
    {
        _suggestionsDebounce?.Cancel();
        var cts = new CancellationTokenSource();
        _suggestionsDebounce = cts;
        _ = DebouncedUpdateSuggestionsAsync(cts.Token);
    }

    private async Task DebouncedUpdateSuggestionsAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(250, token);
            await UpdateSuggestionsAsync(token);
        }
        catch (OperationCanceledException)
        {
            // Superseded by a newer keystroke — expected, not an error.
        }
    }

    private void QueryTextBox_LostFocus(object sender, RoutedEventArgs e) => MaybeAutoFormatJql();

    /// Ctrl-click navigates to the referenced filter (§3.3.1: "mirrors the platform's own
    /// 'follow this reference' convention"), closing the editor and selecting it, same as
    /// clicking it in the sidebar. A plain click opens the picker to change which filter the
    /// chip references. `JqlEditor` raises this from a chip's own `Tapped` handler — a real
    /// UIElement's own hit-testing, not something reverse-engineered from a caret position after
    /// the fact.
    private void QueryTextBox_ChipTapped(object? sender, ChipTappedEventArgs e)
    {
        if (e.CtrlHeld)
        {
            QueryPanel.Visibility = Visibility.Collapsed;
            _ = SelectFilterAsync(e.FilterId);
        }
        else
        {
            OpenChipReferencePicker(e.FilterId);
        }
    }

    /// Search-by-name picker (§3.3.1) — selecting a filter rewrites only that chip's id (a plain
    /// string substitution now that `filter = &lt;id&gt;` is the only representation `Text` ever
    /// has — chip rendering is `JqlEditor`'s concern, not something to patch a display-only copy
    /// of the text for).
    private void OpenChipReferencePicker(string currentFilterId)
    {
        var panel = new StackPanel { Spacing = 6, Width = 220 };
        var searchBox = new TextBox { PlaceholderText = "Search filters…" };
        var list = new ListView { DisplayMemberPath = nameof(FilterRefDto.Name), MaxHeight = 200 };
        panel.Children.Add(searchBox);
        panel.Children.Add(list);
        var flyout = new Flyout { Content = panel };

        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is not FilterRefDto chosen) return;
            flyout.Hide();
            QueryTextBox.Text = Regex.Replace(
                QueryTextBox.Text,
                $@"\bfilter\s*=\s*{Regex.Escape(currentFilterId)}\b",
                $"filter = {chosen.Id}",
                RegexOptions.IgnoreCase);
        };
        searchBox.TextChanged += async (_, _) =>
        {
            try
            {
                list.ItemsSource = Wire.Parse<List<FilterRefDto>>(await SwiraCoreBridge.SearchFiltersAsync(searchBox.Text));
            }
            catch (SwiraNativeException)
            {
                // A transient search failure isn't worth interrupting typing for.
            }
        };

        flyout.ShowAt(QueryTextBox);
        searchBox.Focus(FocusState.Programmatic);
    }

    // ==================== Drag-and-drop filter reference (§3.3.1) ====================

    /// Only a leaf filter row is draggable — group/header rows in the sidebar carry no
    /// `FilterId` and cancel the drag outright.
    private void SidebarList_DragItemsStarting(object sender, DragItemsStartingEventArgs e)
    {
        if (e.Items.Count != 1 || e.Items[0] is not SidebarRow { FilterId: string filterId })
        {
            e.Cancel = true;
            return;
        }
        e.Data.SetText(filterId);
        e.Data.RequestedOperation = DataPackageOperation.Copy;
    }

    private void QueryTextBox_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.Text))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
        }
    }

    /// Inserts at the exact point the drop landed (§3.3.1: "the insertion point is the drop
    /// location itself") — `JqlEditor.HitTestOffset` makes this a real point-to-text-position
    /// hit test, unlike RichEditBox/`ITextDocument`, which had none and fell back to wherever the
    /// caret already happened to be. The connective and enclosing-group rules below still apply
    /// exactly as specified from whatever position that resolves to.
    private async void QueryTextBox_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.Text)) return;
        var filterId = await e.DataView.GetTextAsync();
        if (string.IsNullOrWhiteSpace(filterId) || !filterId.All(char.IsDigit)) return;
        var at = QueryTextBox.HitTestOffset(e.GetPosition(QueryTextBox));
        InsertFilterReference(filterId, at);
    }

    /// Mirrors the web client's drop-insertion rules (§3.3.1): never after a trailing
    /// `ORDER BY`; a connective is added on whichever side doesn't already have one — `OR` if the
    /// enclosing group (or the top level) already uses `OR` anywhere, `AND` otherwise.
    private void InsertFilterReference(string filterId, int at)
    {
        var text = QueryTextBox.Text;
        var orderBy = Regex.Match(text, @"\border\s+by\b", RegexOptions.IgnoreCase);
        var baseEnd = orderBy.Success ? orderBy.Index : text.Length;
        at = Math.Clamp(at, 0, baseEnd);

        var bareBefore = IsBareBefore(text, at);
        var bareAfter = IsBareAfter(text, at);
        var condition = $"filter = {filterId}";
        var piece = condition;
        if (!bareBefore || !bareAfter)
        {
            var (start, end) = EnclosingGroupBounds(text, at);
            // Depth-aware (SplitTopLevelJql, already used by the formatter) — not a bare `\bOR\b`
            // substring search over the whole enclosing span. That naive version was wrong: at the
            // top level, "the whole enclosing span" is the *entire query*, so it picked up an OR
            // sitting inside some unrelated nested paren group (e.g. `(priority = High OR
            // priority = Medium)`) as if it were a top-level connective, even though the top-level
            // clauses were all AND-joined — confirmed live, dropping a reference into
            // `project = PRD AND (priority = High OR priority = Medium) AND status != Done`
            // produced `filter = <id> OR project = PRD ...`, which is wrong per §3.3.1: connective
            // choice is about the enclosing group's own top-level joins, not anything nested
            // inside one of its clauses.
            var (_, connectives) = SplitTopLevelJql(text[start..end]);
            var connective = connectives.Any(c => c == "OR") ? "OR" : "AND";
            if (!bareBefore) piece = $"{connective} {piece}";
            if (!bareAfter) piece = $"{piece} {connective}";
        }

        var before = text[..at];
        var after = text[at..];
        var sep1 = before.Length > 0 && !Regex.IsMatch(before, @"[\s(]$") ? " " : "";
        var sep2 = after.Length > 0 && !Regex.IsMatch(after, @"^[\s)]") ? " " : "";
        var newText = before + sep1 + piece + sep2 + after;
        var newCaret = before.Length + sep1.Length + piece.Length;

        QueryTextBox.Text = newText;
        QueryTextBox.CaretIndex = newCaret;
    }

    /// True at the very start of the text, right after `(`, or right after `AND`/`OR`/`NOT` —
    /// i.e. a connective is already satisfied immediately before `at` and inserting one there too
    /// would produce invalid JQL.
    private static bool IsBareBefore(string text, int at)
    {
        var before = text[..at].TrimEnd();
        return before.Length == 0 || before.EndsWith('(')
            || Regex.IsMatch(before, @"\b(AND|OR|NOT)$", RegexOptions.IgnoreCase);
    }

    /// Mirror of `IsBareBefore` for the other side: end of text, right before `)`, or right
    /// before `AND`/`OR`/`NOT`.
    private static bool IsBareAfter(string text, int at)
    {
        var after = text[at..].TrimStart();
        return after.Length == 0 || after.StartsWith(')')
            || Regex.IsMatch(after, @"^(AND|OR|NOT)\b", RegexOptions.IgnoreCase);
    }

    /// The `[start, end)` span of the innermost parenthesized group `at` sits inside, or the
    /// whole text when it isn't inside any group.
    private static (int Start, int End) EnclosingGroupBounds(string text, int at)
    {
        var depth = 0;
        var start = 0;
        for (var i = at - 1; i >= 0; i--)
        {
            if (text[i] == ')') depth++;
            else if (text[i] == '(')
            {
                if (depth == 0) { start = i + 1; break; }
                depth--;
            }
        }
        depth = 0;
        var end = text.Length;
        for (var i = at; i < text.Length; i++)
        {
            if (text[i] == '(') depth++;
            else if (text[i] == ')')
            {
                if (depth == 0) { end = i; break; }
                depth--;
            }
        }
        return (start, end);
    }

    private void CancelQuery_Click(object sender, RoutedEventArgs e)
    {
        QueryPanel.Visibility = Visibility.Collapsed;
    }

    private async void ApplyQuery_Click(object sender, RoutedEventArgs e)
    {
        await ApplyQueryAsync();
    }

    private async Task ApplyQueryAsync()
    {
        if (_selectedFilter is null) return;
        var jql = QueryTextBox.Text;
        ApplyQueryButton.IsEnabled = false;
        try
        {
            var json = await SwiraCoreBridge.UpdateFilterJqlAsync(_selectedFilter.Id, jql);
            // A validation failure comes back as a ValidationDto (valid:false); success comes
            // back as a FilterDto (no "valid" key). Sniff which one we got.
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("valid", out var validProp) && !validProp.GetBoolean())
            {
                var errors = doc.RootElement.TryGetProperty("errors", out var errs)
                    ? string.Join("\n", errs.EnumerateArray().Select(e => e.GetString()))
                    : "Invalid query.";
                QueryErrors.Text = errors;
                return;
            }
            var updated = Wire.Parse<FilterDto>(json);
            _selectedFilter = updated;
            QueryPanel.Visibility = Visibility.Collapsed;
            await LoadIssuesAsync(updated.Id);
        }
        catch (SwiraNativeException ex)
        {
            QueryErrors.Text = ex.Message;
        }
        finally
        {
            ApplyQueryButton.IsEnabled = true;
        }
    }

    private async void QueryTextBox_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Suggestions list open: arrows navigate it, Tab/Enter accept, Escape dismisses just the
        // list — none of that should also apply/cancel the whole editor (§3.3).
        if (_suggestionFlyout is not null && _suggestionListView is not null)
        {
            var list = _suggestionListView;
            switch (e.Key)
            {
                case VirtualKey.Down:
                    e.Handled = true;
                    list.SelectedIndex = Math.Min(list.SelectedIndex + 1, list.Items.Count - 1);
                    list.ScrollIntoView(list.SelectedItem);
                    return;
                case VirtualKey.Up:
                    e.Handled = true;
                    list.SelectedIndex = Math.Max(list.SelectedIndex - 1, 0);
                    list.ScrollIntoView(list.SelectedItem);
                    return;
                case VirtualKey.Tab:
                case VirtualKey.Enter:
                    if (list.SelectedItem is AutocompleteItemDto chosen)
                    {
                        e.Handled = true;
                        AcceptSuggestion(chosen);
                        return;
                    }
                    break;
                case VirtualKey.Escape:
                    e.Handled = true;
                    CloseSuggestions();
                    return;
            }
        }

        // Ctrl+Enter applies, Escape cancels (§3.3) — scoped to the JQL input, plain Enter stays
        // a literal newline since JQL routinely spans multiple lines.
        var ctrlDown = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (e.Key == VirtualKey.Enter && ctrlDown)
        {
            e.Handled = true;
            await ApplyQueryAsync();
        }
        else if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            QueryPanel.Visibility = Visibility.Collapsed;
        }
    }

    // ==================== JQL autocomplete (§3.3) ====================

    private static readonly Regex TokenFragmentPattern = new(@"[\w.\[\]]*$", RegexOptions.Compiled);
    private static readonly Regex ValueContextPattern = new(
        @"(?<field>[\w.\[\]]+)\s*(?:!=|!~|>=|<=|=|~|>|<)\s*$", RegexOptions.Compiled);

    private AutocompleteDataDto? _autocompleteData;
    private Flyout? _suggestionFlyout;
    private ListView? _suggestionListView;
    private int _suggestionFragmentStart;

    private void CloseSuggestions()
    {
        _suggestionFlyout?.Hide();
        _suggestionFlyout = null;
        _suggestionListView = null;
    }

    /// Scans the token at the caret and shows field/function names, or — once the caret sits
    /// right after a comparison operator — that field's suggested values (§3.3). Anchored on the
    /// editor itself (a `Flyout` built in code, matching the other pickers in this file) rather
    /// than at the exact caret pixel: `RichEditBox`/`ITextDocument` has no supported way to get a
    /// caret's screen position, only a text position.
    private async Task UpdateSuggestionsAsync(CancellationToken token = default)
    {
        var caret = QueryTextBox.CaretIndex;
        var text = QueryTextBox.Text;
        var before = text[..Math.Min(caret, text.Length)];

        var fragmentMatch = TokenFragmentPattern.Match(before);
        var fragment = fragmentMatch.Value;
        if (fragment.Length == 0)
        {
            CloseSuggestions();
            return;
        }
        _suggestionFragmentStart = fragmentMatch.Index;

        var beforeFragment = before[..fragmentMatch.Index];
        var valueContext = ValueContextPattern.Match(beforeFragment);

        List<AutocompleteItemDto> items;
        try
        {
            if (valueContext.Success)
            {
                var field = valueContext.Groups["field"].Value;
                var json = await SwiraCoreBridge.GetJqlSuggestionsAsync(field, fragment);
                token.ThrowIfCancellationRequested();
                items = Wire.Parse<List<AutocompleteItemDto>>(json);
            }
            else
            {
                if (_autocompleteData is null)
                {
                    var json = await SwiraCoreBridge.GetJqlAutocompleteAsync();
                    token.ThrowIfCancellationRequested();
                    _autocompleteData = Wire.Parse<AutocompleteDataDto>(json);
                }
                items = _autocompleteData.Fields.Concat(_autocompleteData.Functions)
                    .Where(f => f.Value.StartsWith(fragment, StringComparison.OrdinalIgnoreCase))
                    .Take(30)
                    .ToList();
            }
        }
        catch (SwiraNativeException)
        {
            CloseSuggestions();
            return;
        }

        // A newer keystroke superseded this request while it was in flight — its result is for a
        // caret position/fragment that's no longer current, so it must not repaint the popup.
        if (token.IsCancellationRequested) return;

        if (items.Count == 0)
        {
            CloseSuggestions();
            return;
        }

        ShowSuggestions(items);
    }

    private void ShowSuggestions(List<AutocompleteItemDto> items)
    {
        var list = new ListView
        {
            ItemsSource = items,
            DisplayMemberPath = nameof(AutocompleteItemDto.Label),
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 220,
            Width = 240,
            SelectedIndex = 0,
        };
        list.ItemClick += (_, e) => AcceptSuggestion((AutocompleteItemDto)e.ClickedItem);
        list.IsItemClickEnabled = true;

        var flyout = new Flyout { Content = list, Placement = FlyoutPlacementMode.Bottom, ShowMode = FlyoutShowMode.Transient };
        _suggestionFlyout = flyout;
        _suggestionListView = list;
        flyout.Closed += (_, _) => { _suggestionFlyout = null; _suggestionListView = null; };
        flyout.ShowAt(QueryTextBox);
        // ShowAt would otherwise steal focus from the editor — keyboard nav needs to keep typing
        // and arrow-keying in QueryTextBox itself.
        QueryTextBox.Focus(FocusState.Programmatic);
    }

    /// Values Jira returns pre-quoted are inserted as-is; unquoted multi-word values are quoted
    /// on insertion (§3.3).
    private void AcceptSuggestion(AutocompleteItemDto item)
    {
        var value = item.Value;
        if (value.Contains(' ') && !value.StartsWith('"') && !value.StartsWith('\''))
        {
            value = $"\"{value}\"";
        }
        var caret = QueryTextBox.CaretIndex;
        var text = QueryTextBox.Text;
        var newText = text[..Math.Min(_suggestionFragmentStart, text.Length)] + value + text[Math.Min(caret, text.Length)..];
        QueryTextBox.Text = newText;
        QueryTextBox.CaretIndex = _suggestionFragmentStart + value.Length;
        CloseSuggestions();
    }

    // ==================== Create filter (stub) ====================

    private async void NewFilter_Click(object sender, RoutedEventArgs e)
    {
        NewFilterNameBox.Text = "";
        NewFilterJqlBox.Text = "";
        NewFilterError.Text = "";
        await NewFilterDialog.ShowAsync();
    }

    /// New filters default to the `Swira` root (§2.3) — a "position" picker (creating in context
    /// under a selected tree node) isn't implemented yet, so the entered name is always appended
    /// as a segment under `Swira: `. Typing more `: `-separated segments still nests correctly,
    /// since this is the same exact-split the core's own `FilterPath` uses.
    private async void NewFilterDialog_PrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            var name = NewFilterNameBox.Text.Trim();
            if (name.Length == 0)
            {
                NewFilterError.Text = "Name is required.";
                args.Cancel = true;
                return;
            }
            var pathSegments = ("Swira: " + name).Split(": ", StringSplitOptions.None);
            var jql = NewFilterJqlBox.Text;

            var json = await SwiraCoreBridge.CreateFilterAsync(
                JsonSerializer.Serialize(pathSegments), jql, description: null);
            var created = Wire.Parse<FilterDto>(json);

            await LoadSidebarAsync(fresh: true);
            await SelectFilterAsync(created.Id);
            // An empty-JQL filter matches everything and would otherwise sit unnoticed — open
            // the query editor immediately so it doesn't (§2.3).
            if (string.IsNullOrEmpty(created.Jql)) EditQuery_Click(this, new RoutedEventArgs());
        }
        catch (SwiraNativeException ex)
        {
            NewFilterError.Text = ex.Message;
            args.Cancel = true;
        }
        finally
        {
            deferral.Complete();
        }
    }

    // ==================== Rename / Delete (§2.3) ====================

    private SidebarRow? _renamingRow;

    /// A favourite's `Path` is a synthetic `\0fav:<id>` key (§2.2's "not a transient identity"
    /// note is about expand-state, but the same non-real value shows up here) — its real full
    /// name is `DisplayName` instead, since a favourite is by definition non-hierarchical.
    private static string FullNameOf(SidebarRow row) => row.Path.StartsWith('\0') ? row.DisplayName : row.Path;

    private async void RenameSidebarItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: SidebarRow row }) return;
        _renamingRow = row;
        RenameNameBox.Text = FullNameOf(row);
        RenameError.Text = "";
        await RenameDialog.ShowAsync();
    }

    private async void RenameDialog_PrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            if (_renamingRow is not { } row) { args.Cancel = true; return; }
            var newName = RenameNameBox.Text.Trim();
            if (newName.Length == 0)
            {
                RenameError.Text = "Name is required.";
                args.Cancel = true;
                return;
            }
            var oldName = FullNameOf(row);
            if (newName == oldName) return;

            if (row.IsGroup)
            {
                await SwiraCoreBridge.RenameBranchAsync(oldName, newName);
            }
            else if (row.FilterId is not null)
            {
                await SwiraCoreBridge.RenameFilterAsync(row.FilterId, newName);
            }
            else
            {
                args.Cancel = true;
                return;
            }
            await LoadSidebarAsync(fresh: true);
        }
        catch (SwiraNativeException ex)
        {
            RenameError.Text = ex.Message;
            args.Cancel = true;
        }
        finally
        {
            deferral.Complete();
        }
    }

    private async void DeleteSidebarItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: SidebarRow row }) return;
        if (row.IsGroup || row.FilterId is null)
        {
            ShowError("Delete a group by deleting its filters individually.");
            return;
        }

        DeleteConfirmText.Text = $"Delete \"{row.DisplayName}\"? This can't be undone.";
        var result = await DeleteConfirmDialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        try
        {
            await SwiraCoreBridge.DeleteFilterAsync(row.FilterId);
            if (_selectedFilter?.Id == row.FilterId)
            {
                _selectedFilter = null;
                FilterTitle.Text = "No filter selected";
                EditQueryButton.IsEnabled = false;
                ColumnsButton.IsEnabled = false;
                RefreshButton.IsEnabled = false;
                SortFieldCombo.IsEnabled = false;
                SortDirButton.IsEnabled = false;
                GroupFieldCombo.IsEnabled = false;
                IssuesList.ItemsSource = null;
                SplitIssuesList.ItemsSource = null;
            }
            await LoadSidebarAsync(fresh: true);
        }
        catch (SwiraNativeException ex)
        {
            ShowError(ex.Message);
        }
    }
}

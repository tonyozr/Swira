using System.Text.Json;
using System.Text.Json.Serialization;

namespace SwiraWin.Native;

// Wire shapes mirror Sources/SwiraABI/SwiraABI.swift's DTOs (which in turn mirror
// Sources/swira-web/WebAPI.swift) verbatim — same JSON contract, three different processes
// producing/consuming it. Property names match the Swift side's field names exactly, so no
// [JsonPropertyName] overrides are needed as long as System.Text.Json's default (case-sensitive,
// as-declared) naming policy is used — see JsonOptions below.

public static class JsonOptions
{
    public static readonly JsonSerializerOptions Default = new()
    {
        PropertyNameCaseInsensitive = true,
    };
}

public sealed class FilterDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Jql { get; set; }
    public bool Favourite { get; set; }
    public string? ViewUrl { get; set; }
    public List<string> PathSegments { get; set; } = [];
}

public sealed class NodeDto
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public FilterDto? Filter { get; set; }
    public List<NodeDto> Children { get; set; } = [];
}

public sealed class SidebarDto
{
    public List<FilterDto> Favourites { get; set; } = [];
    public List<NodeDto> Tree { get; set; } = [];
    public MetaDto? Meta { get; set; }
}

/// Freshness metadata (§3.4) — the client must be able to say "as of 12:04" and never present
/// stale data as current.
public sealed class MetaDto
{
    public string Origin { get; set; } = "network";
    public bool IsStale { get; set; }
    public DateTimeOffset? StoredAt { get; set; }
}

public sealed class ColumnRefDto
{
    public string Label { get; set; } = "";
    public string Value { get; set; } = "";
}

public sealed class IssueDto
{
    public string Key { get; set; } = "";
    public string? Summary { get; set; }
    public string? Status { get; set; }
    public string? StatusCategory { get; set; }
    public string? IssueType { get; set; }
    public string? Priority { get; set; }
    public string? Assignee { get; set; }
    public DateTimeOffset? Updated { get; set; }
    public string BrowseUrl { get; set; } = "";
    public Dictionary<string, JsonElement> Fields { get; set; } = [];
}

public sealed class IssuesDto
{
    public List<IssueDto> Issues { get; set; } = [];
    public string? NextPageToken { get; set; }
    public List<ColumnRefDto> Columns { get; set; } = [];
}

public sealed class ValidationDto
{
    public bool Valid { get; set; }
    public List<string> Errors { get; set; } = [];
}

public sealed class ColumnsDto
{
    public List<ColumnRefDto> Columns { get; set; } = [];
}

public sealed class FilterRefDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
}

public sealed class FieldRefDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
}

public sealed class AutocompleteItemDto
{
    public string Value { get; set; } = "";
    public string Label { get; set; } = "";
}

public sealed class AutocompleteDataDto
{
    public List<AutocompleteItemDto> Fields { get; set; } = [];
    public List<AutocompleteItemDto> Functions { get; set; } = [];
}

public sealed class PriorityRefDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? IconUrl { get; set; }
}

public sealed class UserRefDto
{
    public string AccountId { get; set; } = "";
    public string DisplayName { get; set; } = "";
}

public sealed class VersionRefDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public bool Released { get; set; }
}

public sealed class TransitionDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? ToStatusName { get; set; }
}

/// Parses one of the JSON payloads `SwiraCoreBridge` returns, using case-insensitive property
/// matching so this file doesn't need a `[JsonPropertyName]` on every property.
public static class Wire
{
    public static T Parse<T>(string json) => JsonSerializer.Deserialize<T>(json, JsonOptions.Default)!;
}

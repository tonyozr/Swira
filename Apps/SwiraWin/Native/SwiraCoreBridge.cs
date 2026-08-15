using System.Runtime.InteropServices;

namespace SwiraWin.Native;

/// Thrown when a `swira_*` native call fails; `Message` is `swira_last_error()`'s text, the same
/// human-readable string `SwiraError.errorDescription` produces on the Swift side.
public sealed class SwiraNativeException(string message) : Exception(message);

/// P/Invoke surface over `SwiraABI.dll` (Sources/SwiraABI/SwiraABI.swift). This is the entire
/// boundary between SwiraWin's XAML/C# and `SwiraCore`: every Jira call funnels through here,
/// nothing talks to Jira or to `swira-web` directly. Async native calls are bridged to
/// `Task&lt;string&gt;` (raw JSON) via a `TaskCompletionSource` pinned behind a `GCHandle`, handed to
/// the native side as the callback's opaque context and recovered when it fires.
public static unsafe class SwiraCoreBridge
{
    private const string Lib = "SwiraABI.dll";

    private delegate void ReplyDelegate(byte* json, IntPtr context);

    [DllImport(Lib)] private static extern int swira_configure();
    [DllImport(Lib)] private static extern IntPtr swira_last_error();
    [DllImport(Lib)] private static extern void swira_free_string(IntPtr ptr);

    [DllImport(Lib)]
    private static extern void swira_get_sidebar(
        int fresh, delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback, IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_get_filter_issues(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? sortField,
        int sortDirDescending,
        int limit,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? pageToken,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_validate_jql(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string jql,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_update_filter_jql(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string jql,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_get_columns(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_set_columns(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string fieldIdsJson,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_reset_columns(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib)]
    private static extern void swira_get_fields(delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback, IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_set_issue_text(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string fieldId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string value,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_search_filters(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_create_filter(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string pathSegmentsJson,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string jql,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? description,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_delete_filter(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_rename_filter(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filterId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string newName,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_rename_branch(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string oldPrefix,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string newPrefix,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib)]
    private static extern void swira_get_priorities(delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback, IntPtr context);

    [DllImport(Lib)]
    private static extern void swira_jql_autocomplete(delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback, IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_jql_suggestions(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string fieldName,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? fieldValue,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_search_users(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_get_project_versions(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string projectIdOrKey,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_get_transitions(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_set_issue_priority(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string priorityId,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_set_issue_assignee(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? accountId,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_set_issue_labels(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string labelsJson,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_set_issue_fixversions(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string versionIdsJson,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    [DllImport(Lib, CharSet = CharSet.Ansi)]
    private static extern void swira_transition_issue(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string issueKey,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string transitionId,
        delegate* unmanaged[Cdecl]<byte*, IntPtr, void> callback,
        IntPtr context);

    /// Reads `JIRA_URL`/`JIRA_EMAIL`/`JIRA_API_TOKEN` (see `SwiraConfiguration.fromEnvironment`)
    /// from this process's own environment and assembles the core. Call once at startup.
    public static bool Configure(out string? error)
    {
        var ok = swira_configure() != 0;
        error = ok ? null : LastError();
        return ok;
    }

    public static Task<string> GetSidebarAsync(bool fresh)
    {
        var (tcs, context) = BeginCall();
        swira_get_sidebar(fresh ? 1 : 0, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetFilterIssuesAsync(
        string filterId, string? sortField, bool descending, int limit, string? pageToken)
    {
        var (tcs, context) = BeginCall();
        swira_get_filter_issues(filterId, sortField, descending ? 1 : 0, limit, pageToken, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> ValidateJqlAsync(string jql)
    {
        var (tcs, context) = BeginCall();
        swira_validate_jql(jql, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> UpdateFilterJqlAsync(string filterId, string jql)
    {
        var (tcs, context) = BeginCall();
        swira_update_filter_jql(filterId, jql, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetColumnsAsync(string filterId)
    {
        var (tcs, context) = BeginCall();
        swira_get_columns(filterId, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SetColumnsAsync(string filterId, string fieldIdsJson)
    {
        var (tcs, context) = BeginCall();
        swira_set_columns(filterId, fieldIdsJson, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> ResetColumnsAsync(string filterId)
    {
        var (tcs, context) = BeginCall();
        swira_reset_columns(filterId, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetFieldsAsync()
    {
        var (tcs, context) = BeginCall();
        swira_get_fields(&OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SetIssueTextAsync(string issueKey, string fieldId, string value)
    {
        var (tcs, context) = BeginCall();
        swira_set_issue_text(issueKey, fieldId, value, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SearchFiltersAsync(string query)
    {
        var (tcs, context) = BeginCall();
        swira_search_filters(query, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> CreateFilterAsync(string pathSegmentsJson, string jql, string? description)
    {
        var (tcs, context) = BeginCall();
        swira_create_filter(pathSegmentsJson, jql, description, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetJqlAutocompleteAsync()
    {
        var (tcs, context) = BeginCall();
        swira_jql_autocomplete(&OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetJqlSuggestionsAsync(string fieldName, string? fieldValue)
    {
        var (tcs, context) = BeginCall();
        swira_jql_suggestions(fieldName, fieldValue, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> DeleteFilterAsync(string filterId)
    {
        var (tcs, context) = BeginCall();
        swira_delete_filter(filterId, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> RenameFilterAsync(string filterId, string newName)
    {
        var (tcs, context) = BeginCall();
        swira_rename_filter(filterId, newName, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> RenameBranchAsync(string oldPrefix, string newPrefix)
    {
        var (tcs, context) = BeginCall();
        swira_rename_branch(oldPrefix, newPrefix, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetPrioritiesAsync()
    {
        var (tcs, context) = BeginCall();
        swira_get_priorities(&OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SearchUsersAsync(string query)
    {
        var (tcs, context) = BeginCall();
        swira_search_users(query, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetProjectVersionsAsync(string projectIdOrKey)
    {
        var (tcs, context) = BeginCall();
        swira_get_project_versions(projectIdOrKey, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> GetTransitionsAsync(string issueKey)
    {
        var (tcs, context) = BeginCall();
        swira_get_transitions(issueKey, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SetIssuePriorityAsync(string issueKey, string priorityId)
    {
        var (tcs, context) = BeginCall();
        swira_set_issue_priority(issueKey, priorityId, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SetIssueAssigneeAsync(string issueKey, string? accountId)
    {
        var (tcs, context) = BeginCall();
        swira_set_issue_assignee(issueKey, accountId, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SetIssueLabelsAsync(string issueKey, string labelsJson)
    {
        var (tcs, context) = BeginCall();
        swira_set_issue_labels(issueKey, labelsJson, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> SetIssueFixVersionsAsync(string issueKey, string versionIdsJson)
    {
        var (tcs, context) = BeginCall();
        swira_set_issue_fixversions(issueKey, versionIdsJson, &OnReply, context);
        return tcs.Task;
    }

    public static Task<string> TransitionIssueAsync(string issueKey, string transitionId)
    {
        var (tcs, context) = BeginCall();
        swira_transition_issue(issueKey, transitionId, &OnReply, context);
        return tcs.Task;
    }

    private static string LastError()
    {
        var ptr = swira_last_error();
        // Owned by SwiraABI (a global buffer refreshed on each failure) — never freed here.
        return ptr == IntPtr.Zero ? "Unknown native error." : (Marshal.PtrToStringUTF8(ptr) ?? "Unknown native error.");
    }

    /// A `delegate* unmanaged<...>` function-pointer type can't appear as a generic type
    /// argument (CS0306), which rules out a shared `Invoke(Action&lt;callback, context&gt; call)`
    /// helper — each public method above passes `&OnReply` at its own call site instead; this
    /// just factors out the bookkeeping common to all of them.
    private static (TaskCompletionSource<string> Tcs, IntPtr Context) BeginCall()
    {
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handle = GCHandle.Alloc(tcs);
        return (tcs, GCHandle.ToIntPtr(handle));
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvCdecl)])]
    private static void OnReply(byte* json, IntPtr context)
    {
        var handle = GCHandle.FromIntPtr(context);
        var tcs = (TaskCompletionSource<string>)handle.Target!;
        handle.Free();

        if (json == null)
        {
            tcs.TrySetException(new SwiraNativeException(LastError()));
            return;
        }
        var text = Marshal.PtrToStringUTF8((IntPtr)json) ?? "";
        tcs.TrySetResult(text);
    }
}

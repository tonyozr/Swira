# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```powershell
swift build
swift test                          # offline, self-contained — must stay green
swift test --filter <SuiteOrTestName>
```

A `Makefile` wraps these same verbs (`make build`, `make build CONFIG=release`, `make test`,
`make test FILTER=<Name>`, `make clean`, `make help`) so the build is reachable the same way on
every platform. On Windows, `build`/`clean` also cover `Apps/SwiraWin` via `dotnet` — there's no
separate per-subproject target, `make build` just builds everything buildable on the current
platform. **If SwiftPM is ever replaced or supplemented by another build system, keep it callable
through these same `make` targets** — update the Makefile's recipes rather than teaching people a
second, parallel set of commands.

- `Live Jira` (`Tests/SwiraCoreTests/LiveJiraTests.swift`) is a read-only integration suite,
  auto-skipped unless `JIRA_URL` / `JIRA_EMAIL` / `JIRA_API_TOKEN` are set. It never creates,
  modifies, or deletes anything — do not add mutating live tests without the user's explicit
  go-ahead (see the memory file on live-Jira restraint).
- `swift run swira-probe <subcommand>` — manual CLI for exercising the core against a real site
  (`whoami`, `filters list`, `jql validate`, `search`, `get <path>` for raw JSON, `cache --clear`).
- `swift run swira-web [--port 8787]` — runs the local web client (embedded HTML/CSS/JS + JSON
  API). Default port 8787. **On Windows, a running `swira-web.exe` holds a file lock that makes
  `swift build` fail with a linker "permission denied" error.** Before rebuilding, find and stop
  it: `Get-NetTCPConnection -LocalPort 8787 -State Listen`, confirm the PID is really
  `swira-web.exe` via `Get-Process -Id <pid> | Select Path`, then `Stop-Process -Id <pid> -Force`
  — or just run `make stop-web`, which does the same check-and-kill on Windows/macOS/Linux.

## Architecture

Swira is a Jira Cloud filter-management client: a reusable, platform-agnostic Swift core
(`SwiraCore`) plus thin clients built on top of it. Call chain:
`Service → Endpoint → JiraClient (actor) → HTTPTransport → network`, with `CacheStore` plugged in
at the `JiraClient` level (ETag/304) and the `Service` level (cache-policy per read).

- **`SwiraCore` must build and pass tests on Windows** (development happens there; targets are
  macOS/Windows/Linux) and imports neither AppKit nor SwiftUI. Development is on Windows,
  x86_64-unknown-windows-msvc, Swift 6.3.3; runtime clients target macOS (and later Windows/WinUI).
  This is why transport avoids relying on flaky corelibs-Foundation async `URLSession` behavior,
  cache is flat JSON files (no SQLite), and cache paths go through `CacheLocation` rather than
  `~/Library`.
- **Cloud vs. Data Center dialects are hidden behind one public API.** Set `JIRA_API_VERSION=2`
  to target Server/Data Center (REST v2); the deployment is inferred from the API version and
  services silently switch request/response shape (issue search offset-vs-cursor, JQL validation
  via dry-search vs. `/jql/parse`, filter listing endpoints, user identity field, etc. — see the
  table in README.md). Callers never see which dialect answered. When touching a `Service`, check
  whether behavior needs to branch on `deployment` (see `IssueServiceTests` for the pattern of
  paired Cloud/DataCenter tests).
- **Two incompatible pagination models exist and must not be conflated:** `OffsetPage<T>`
  (`startAt`/`maxResults`/`total`/`isLast`, used by `/filter/search` and reference endpoints) vs.
  `TokenPage<T>` (`nextPageToken`, used by `/search/jql` — the old `POST /rest/api/3/search` is
  gone, returns `410`). `PagedSequence<T>` is the single `AsyncSequence` that walks either one
  with a hard cap against a runaway cursor.
- **Errors are unified into `SwiraError`** (`Support/SwiraError.swift`) with `errorDescription`,
  `isRetryable`, and `suggestsReauth` — clients render/react without re-deriving HTTP semantics.
- **`Secret` (Auth/Secret.swift) redacts tokens even in `description`/error text** — never bypass
  this by logging or interpolating raw credential strings.
- **Filter hierarchy is encoded into flat Jira filter names.** Jira has no folders; Swira joins
  path segments with `": "` (e.g. `Swira: Versions: Current`). `FilterPath` converts names ↔
  segment paths (exact round-trip); `FilterTree.build(from:)` reassembles the forest, producing
  *virtual* nodes at branch points that have no filter of their own. Any other Jira client just
  sees an ordinary filter name.
- **Caching is `Cached<T>`-returning and policy-driven** (`.networkOnly`, `.cacheFirst(ttl:)`,
  `.staleWhileRevalidate`, `.cacheOnly`), so UIs can honestly show "data from Xm ago, offline"
  instead of silently serving stale data as fresh. Mutations always hit the network and invalidate
  affected cache keys. Issue search results and anything containing credentials are never cached.
- **`Models/JiraIssue.swift`'s `Issue.fields` is a loosely-typed `[String: JSONValue]`** (see
  `Support/JSONValue.swift`) rather than a fully-typed model — Jira's field set is
  project/instance-specific and unbounded (including custom fields), so typing it exhaustively
  isn't attempted; typed convenience accessors are added only where a service actually needs one.
- **`swira-web`** is the first concrete client of `docs/CLIENT-SPEC.md` — the platform-agnostic
  behavior spec every client (web, future macOS/Windows native apps) must follow. `WebUI.swift`
  is a single embedded HTML/CSS/JS string (contenteditable JQL editor with chip rendering,
  syntax highlighting, autocomplete, floating pickers for assignee/labels/fixVersions);
  `WebAPI.swift` is the JSON API surface; `HTTPServer.swift` is a minimal loopback-only HTTP
  server. When changing client-visible behavior, update `docs/CLIENT-SPEC.md` to match — it's the
  cross-client source of truth, not a description of what `swira-web` happens to do.
  - CSS gotcha specific to the floating pickers: a flex child's default `min-height: auto` blocks
    it from scrolling inside a height-constrained flex parent even with `flex: 1 1 auto` —
    `min-height: 0` is required. Also, `positionFloatingPicker`'s inline `display` write can beat
    a picker's own CSS `display` rule; branch on the picker's id rather than hardcoding `"block"`.
- Live browser verification of `swira-web` changes uses the `mcp__claude-in-chrome__*` tools
  against the locally running dev server. Never trigger native `confirm()`/`alert()` dialogs via
  automation (the app's delete-filter flow uses `confirm(...)`) — use `javascript_tool` to call
  the DELETE API directly instead, plus manual state/DOM cleanup, when a test filter needs removal.
- **`SwiraWin` (`Apps/SwiraWin`) is C#/WinUI 3, the one non-Swift piece of the stack** — WinUI's
  XAML surface has no public non-.NET API, and a full Swift-native UI (thebrowsercompany's
  swift-winrt) needs their experimental toolchain fork, not the stock release compiler this repo
  otherwise builds with. Every Jira call still goes through `SwiraCore`: `Sources/SwiraABI`
  exposes it as a flat, callback-based C ABI (`@_cdecl`, built as a Windows DLL — `swift build
  --product SwiraABI`), which `Apps/SwiraWin/Native/SwiraCoreBridge.cs` P/Invokes directly. No
  HTTP, no `swira-web` subprocess — this is the "local IPC" alternative the plan named, just
  in-process rather than over a loopback socket. New async operations get added in pairs: a
  `@_cdecl` function in `SwiraABI.swift` (callback-based, JSON in/out, DTOs mirroring
  `WebAPI.swift`'s wire shapes) plus the matching `DllImport`/`Task<string>` wrapper in
  `SwiraCoreBridge.cs`.
  - `dotnet build` in `Apps/SwiraWin` needs `SwiraABI.dll` already built and copied in (the
    `.csproj` does the copy automatically if `.build/debug|release/SwiraABI.dll` exists — build
    SwiraABI first).
  - **This dev machine has no Visual Studio, only the .NET SDK** — several of Microsoft.WindowsAppSDK's
    imported MSBuild targets need VS-provided task assemblies
    (`Microsoft.Build.Packaging.Pri.Tasks.dll`, `Microsoft.Build.AppxPackage.dll`) that don't
    exist here. `Apps/SwiraWin/Directory.Build.targets` overrides the MSIX-packaging-only ones as
    no-ops (irrelevant to an unpackaged app) and reimplements `resources.pri` generation by
    shelling out to the Windows SDK's `makepri.exe` directly — **do not remove or "clean up"**
    these overrides without first confirming Visual Studio's AppxPackage tooling is actually
    installed; without them (or without a real VS), the build fails with `MSB4062` errors, and
    without a `resources.pri` specifically, the app builds but **crashes on launch**
    (`0xC000027B` inside `Microsoft.UI.Xaml.dll` — WinUI's default control styles are
    resource-indexed and the WinRT `ResourceManager` has nothing to resolve them against).
  - **`0xC000027B` inside `Microsoft.UI.Xaml.dll` is not unique to the missing-`resources.pri`
    case above — it's also what a plain, catchable .NET exception looks like from the outside
    when it escapes an `[UnmanagedCallersOnly]` method.** `SwiraCoreBridge`'s reply callback
    (`OnReply`, invoked from Swift via `&OnReply`) resumes a `LoadIssuesAsync`/etc. continuation
    from inside that native call; any exception thrown in code that runs as part of that
    continuation (e.g. a XAML resource lookup that throws `KeyNotFoundException`) doesn't surface
    as a normal catchable exception — the .NET runtime `FailFast`s the whole process, and Windows
    Error Reporting logs it as the exact same fault signature as the resources.pri case. Confirmed
    by reproducing it: `Application.Current.Resources.ThemeDictionaries[...]` throwing inside a
    `LoadIssuesAsync` continuation. If this crash recurs, don't assume it's `resources.pri` stale
    again — check timestamps first (`ls` the `.pri` file vs the `.exe`), and if they're already
    fresh, suspect a throwing continuation instead. General rule: any code that runs as part of a
    `SwiraCoreBridge`-await continuation must not let exceptions escape uncaught (or must avoid
    APIs that can throw for reasons outside your control, like blind resource-dictionary
    indexing) — wrap it defensively, because normal `try`/`catch` at the call site won't save you
    once it's already unwound through the native boundary.
  - **This same XamlCompiler.exe (Windows App SDK 1.6, .NET Framework 4.7.2, no Visual Studio)
    hard-crashes on `ListView.GroupStyle`/`GroupStyle.HeaderTemplate` and on any custom
    `DataTemplateSelector` referenced from XAML** — `MSB3073`/exit code 1 with zero diagnostic
    text on either stdout or stderr, not an ordinary XAML parse error. Confirmed by bisection
    with clean `obj`/`bin` each time (not a stale-incremental-cache artifact); plain `x:Bind` vs.
    classic `{Binding}` made no difference. Group headers in the table/split views are therefore
    ordinary `IssueRow`s (`IsGroupHeader = true`) rendered through the same single
    `ListView.ItemTemplate` every other row uses, not a second template or `GroupStyle` — see
    `ApplyGrouping` in `MainWindow.xaml.cs`. If a real Visual Studio install is ever available,
    it's worth retrying `GroupStyle`/`DataTemplateSelector` there — the crash may be specific to
    this bare-SDK toolchain, in which case the workaround could be dropped in favor of the more
    idiomatic approach.
  - **Screenshots taken via UI automation in this dev/test environment render the window's client
    area solid black**, regardless of `SystemBackdrop`/Mica — confirmed by building and launching
    with Mica explicitly disabled and observing the same black rectangle, with the process alive
    and `Responding: True` and no crash event logged. This points to a Composition/DWM rendering
    limitation of the sandboxed/remote session used for automation here (no GPU acceleration,
    likely), not an app bug — real hardware should render normally. Don't treat a black screenshot
    alone as proof of a rendering regression; corroborate with process health and, where possible,
    testing on a non-sandboxed machine before "fixing" anything based on it.

## Conventions

- Tests use **swift-testing** (`@Suite`/`@Test`/`#expect`/`#require`), not XCTest.
- `MockTransport` (`Tests/SwiraCoreTests/MockTransport.swift`) stubs `HTTPTransport` and records
  requests for assertion; fixtures live in `Tests/SwiraCoreTests/Fixtures/`.
- Strict Swift 6 concurrency throughout: mutable state lives in actors (`JiraClient`,
  `FileSystemCacheStore`, services), models are immutable `Sendable`/`Codable`/`Equatable` value
  types. Avoid `@unchecked Sendable`.

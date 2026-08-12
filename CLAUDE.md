# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```powershell
swift build
swift test                          # offline, self-contained — must stay green
swift test --filter <SuiteOrTestName>
```

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
  `swira-web.exe` via `Get-Process -Id <pid> | Select Path`, then `Stop-Process -Id <pid> -Force`.

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

## Conventions

- Tests use **swift-testing** (`@Suite`/`@Test`/`#expect`/`#require`), not XCTest.
- `MockTransport` (`Tests/SwiraCoreTests/MockTransport.swift`) stubs `HTTPTransport` and records
  requests for assertion; fixtures live in `Tests/SwiraCoreTests/Fixtures/`.
- Strict Swift 6 concurrency throughout: mutable state lives in actors (`JiraClient`,
  `FileSystemCacheStore`, services), models are immutable `Sendable`/`Codable`/`Equatable` value
  types. Avoid `@unchecked Sendable`.

# Swira

A client for managing Jira Cloud filters.

The project consists of a reusable Swift core and several clients built on top of it:

| Component | Status |
|---|---|
| `SwiraCore` — core library | in progress |
| `swira-probe` — utility CLI for manually exercising the core | in progress |
| `swira-web` — web client served on localhost | MVP |
| `swira-cli` — terminal client built on [SwiftTUI](https://github.com/SwiftTUI/swift-tui) | planned (no Windows dev support in the framework) |
| `SwiraMac` — native macOS app (AppKit) | planned |
| `SwiraWin` — native Windows app (WinUI) | planned |

## Requirements

- Swift 6.1+ (developed against 6.3.3)
- macOS 14+, Windows 10+, Linux

`SwiraCore` depends on neither AppKit nor SwiftUI and builds on all three platforms.

## Configuration

The core reads its settings from environment variables:

| Purpose | Variables (in priority order) |
|---|---|
| Jira site URL | `SWIRA_JIRA_URL`, `JIRA_URL`, `JIRA_BASE_URL` |
| Login (email) | `JIRA_EMAIL`, `JIRA_USER` |
| API token | `JIRA_API_TOKEN`, `JIRA_TOKEN`, `JIRA_PAT` |

Create an API token at https://id.atlassian.com/manage-profile/security/api-tokens

```powershell
$env:JIRA_URL = 'https://your-site.atlassian.net'
$env:JIRA_EMAIL = 'you@example.com'
$env:JIRA_API_TOKEN = '<token>'

swift run swira-probe whoami
```

If a token is present but no email is set, the `Bearer` scheme is used instead
(Jira Data Center / PAT).

## Clients

The UI and behaviour all clients implement is specified in
[docs/CLIENT-SPEC.md](docs/CLIENT-SPEC.md). The canonical client is the native macOS app;
terminal, GNUstep, Windows, and web implementations follow the same specification in their
platform's idiom.

## Filter hierarchy

Jira stores filters flat; Swira encodes a tree into their names. Path segments are joined with
`": "` (colon-space), so the filter named `Swira: Versions: Current` is the node `Current` under
`Versions` under the root `Swira`. Any other Jira client just sees an ordinary name — the scheme
needs nothing from the server and degrades gracefully.

- `FilterPath` converts between names and segment paths (exact round-trip; a bare `:` without a
  space does not split).
- `FilterTree.build(from:)` reassembles the forest from any flat filter list. Branch points
  without a filter of their own become *virtual* nodes; a node can be a filter and a parent at
  the same time.
- `FiltersService.tree()` builds the tree over the user's own and favourite filters.
- `FiltersService.create(at:jql:)` creates a filter at a path. Clients create under the
  `Swira` root by default (`FilterPath.defaultRoot`), but any root is valid.

## Cloud and Data Center

The core targets Jira Cloud (REST v3) first, and also supports classic Jira Server / Data Center
(REST v2). Set `JIRA_API_VERSION=2` — the deployment is inferred from the API version, and the
services silently switch dialects where the two APIs diverge:

| Capability | Cloud | Server / Data Center |
|---|---|---|
| Issue search | `POST /search/jql` (cursor) | `POST /search` (offset, bridged into the same cursor API) |
| Match count | `/search/approximate-count` | `total` of a zero-result search (exact) |
| JQL validation | `POST /jql/parse` | zero-result dry search; a 400 envelope becomes the verdict |
| Filter listing | `/filter/search`, `/filter/my` | `/filter/favourite`, filtered client-side |
| Project listing | `/project/search` (paginated) | `/project` (flat list, paginated client-side) |
| User identity | `accountId` | `key` / `name`, mapped onto the same field |

The public service API is identical on both; callers never see which dialect answered.

## Using the core

```swift
import SwiraCore

let swira = try Swira.fromEnvironment()
try await swira.verifyCredentials()

// Reads report where the data came from, so a UI can say "cached, 4 minutes old"
// rather than passing stale data off as current.
let result = try await swira.filters.search(FilterQuery(name: "bugs"))
print(result.origin, result.isStale)

for filter in result.value.values {
    print(filter.name, filter.jql ?? "")
}

// Walk every page without touching offsets.
for try await filter in swira.filters.all() {
    print(filter.name)
}

// Check a query before saving it, instead of surfacing a raw 400.
let check = try await swira.jql.validate("project = SWIRA AND status != Done")
guard check.isValid else { throw SomeError(check.errors) }

// Preview what a filter matches.
let preview = try await swira.search.preview(filterId: "10000", limit: 25)
```

### Caching and offline reads

Reads take a `CachePolicy` and return `Cached<T>`:

| Policy | Behaviour |
|---|---|
| `.networkOnly` | Always fetch. Falls back to cache only if the network fails outright. |
| `.cacheFirst(ttl:)` | Serve from cache while younger than `ttl`, else revalidate (via `ETag`). |
| `.staleWhileRevalidate` | Return cached immediately, refresh in the background. |
| `.cacheOnly` | Never touch the network; throws `.offline` if nothing is cached. |

When the network fails and a cached copy exists, it is returned with `isStale == true` rather than
throwing — but HTTP errors such as `401` are never masked this way, so revoked credentials still
surface. Mutations invalidate every cached filter response.

## swira-web

Serves the browser client on localhost:

```powershell
swift run swira-web                       # http://127.0.0.1:8787/
swift run swira-web --port 9000
swift run swira-web --socket /tmp/swira.sock   # Unix domain socket instead of TCP
```

`--socket` binds a Unix domain socket at the given path instead of a TCP port (`--port` is
ignored when it's set), for callers that front the client with their own reverse proxy or
sandbox rather than exposing a loopback port. Works on Windows too (`AF_UNIX` support has
shipped there since the Windows 10 1803 SDK), not just macOS/Linux. A stale socket file left
over from a previous run is replaced automatically.

## swira-probe

A plain CLI for exercising the core against a real site:

```powershell
swift run swira-probe whoami
swift run swira-probe filters list --name bugs
swift run swira-probe filters show 10000 --preview 5
swift run swira-probe filters list --offline      # read from cache only
swift run swira-probe jql validate "project = SWIRA"
swift run swira-probe search "assignee = currentUser()" --count
swift run swira-probe get filter/search -q maxResults=1   # raw JSON, for when docs disagree
swift run swira-probe cache --clear
```

## Building

```
swift build
swift test
```

The test suite is self-contained and runs offline. One suite — `Live Jira` — additionally runs
read-only integration tests against a real site, and is skipped automatically unless the
`JIRA_URL` / `JIRA_EMAIL` / `JIRA_API_TOKEN` environment variables are set. It never creates,
modifies, or deletes anything on the site.

A `Makefile` wraps the common verbs so they work the same way on macOS, Windows, and Linux:

```
make build                  # swift build
make test                   # swift test
make test FILTER=Foo        # swift test --filter Foo
make run-probe ARGS="whoami"
make run-web PORT=8787      # swift run swira-web
make stop-web                # stop whatever is listening on PORT (default 8787)
make clean                  # swift package clean
make help
```

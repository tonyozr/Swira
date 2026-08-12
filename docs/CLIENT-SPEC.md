# Swira Client Specification

This document specifies the user interface and behaviour of Swira clients. The **canonical
client is the native macOS application**; it defines the reference behaviour. Every other
implementation — terminal (TUI), GNUstep, Windows (WinUI), web — MUST provide the same
structure and behaviour, translated into its platform's idiom. Where a rule genuinely cannot
be met on a platform, the closest equivalent MUST be provided and the deviation documented.

The keywords MUST, SHOULD, and MAY are used in their usual normative sense.

All data access goes through `SwiraCore`; clients MUST NOT talk to Jira directly. Core
concepts referenced below: `JiraFilter`, `FilterPath` / `FilterTree` (the name-encoded
hierarchy, separator `": "`), `Cached<T>` (value plus origin and staleness), and the
creation-time favourite default: standalone (non-hierarchical) filters are always created as
favourites, since Favourites is the only place they are ever shown. Hierarchical filters are
created non-favourite on Cloud, since the tree already makes them visible there — but always
favourite on Data Center, a deployment-specific workaround (`FiltersService.create`) for its
missing `filter/search`/`filter/my` endpoints (§2.1).

---

## 1. Window model

The client presents **one window** with two permanent regions:

```
┌────────────┬──────────────────────────────────────────────┐
│            │  toolbar: [view switcher] [edit query] …     │
│  sidebar   ├──────────────────────────────────────────────┤
│            │                                              │
│ FAVOURITES │           content area                       │
│  ⭐ …      │   (table view  OR  split view,               │
│  ⭐ …      │    for the selected filter)                  │
│            │                                              │
│ FILTERS    │                                              │
│  ▸ Swira   │                                              │
│    ▸ …     │                                              │
│            │                                              │
│    [+]     │                                              │
└────────────┴──────────────────────────────────────────────┘
```

There are no other top-level windows. Dialogs (query editor, column chooser, creation form)
attach to this window in the platform's native transient style.

---

## 2. Sidebar

The sidebar contains exactly two sections, in this order, and nothing else.

### 2.1 Favourites

- Lists every favourite filter **whose name has no hierarchy separator** — a plain name like
  `Jira 8`. This is the only place such a filter is ever shown.
- Source: `FiltersService.favourites()`, filtered to exclude anything also shown in the filter
  tree (§2.2).
- A hierarchical filter is never listed here, even when it is favourite. On Cloud this
  distinction is mostly moot (hierarchical filters default to non-favourite); on Data Center,
  where every filter is created favourite as a workaround (see the intro), it matters —
  without this exclusion, every hierarchical filter would visibly double up in Favourites.

### 2.2 Filter tree

- Below Favourites, lists **every filter whose name contains the hierarchy separator
  `": "`**, rendered as a tree via `FilterTree.build(from:)`. Favourite status is irrelevant to
  whether a filter appears here — only its name shape decides that.
- Filters without the separator do NOT appear in this section.
- Branch points with no filter of their own (virtual nodes) are rendered as plain,
  non-selectable-as-filter group rows; they expand and collapse but do not open a query.
- Ordering within a level: case-insensitive by name (the order `FilterTree` produces).
- Each branch's expanded/collapsed state MUST persist across restarts, keyed by its full path
  (not a transient identity like a DOM node or list index) — the tree looks the same the next
  time the client opens instead of resetting to fully expanded.

### 2.3 Sidebar actions

- **Create (+):** creates a new filter. The creation form asks for a name/position and JQL.
  New filters default to the `Swira` root (`FilterPath.defaultRoot`) when created from the
  tree's top level, or to the selected node's path when created in context. Any root is
  legal; `Swira` is only the default. Filters created at a hierarchical path are
  non-favourite on Cloud (core default) and favourite on Data Center (§2.1, a
  visibility workaround — it does not affect where the filter is shown, since the tree
  section ignores favourite status); a filter created as a standalone name outside any tree
  position is always created as a favourite, since that is the only way it stays visible. JQL
  MAY be left empty — a filter with no conditions is valid and simply matches everything the
  account can see.
- **After creation**, the client MUST select and open the new filter immediately, the same as
  clicking it in the sidebar, rather than leaving the user to find it themselves. If it was
  created with empty JQL, the client MUST also open the query editor (§3.3) immediately
  afterward, so an empty filter doesn't sit unnoticed with nothing to narrow it.
- In the creation form, Enter MUST submit (same as the primary action button) from any
  single-line field; in a multi-line field (the JQL input), Enter MUST behave as a plain
  newline instead, since JQL routinely spans multiple lines.
- **Move (drag & drop within the tree):** moving a node is **a rename** — the filter's name
  is rewritten to the new path (`FilterPath` recomposition). Moving a branch renames every
  filter in its subtree. Clients MUST present this as a move; there is no other "move"
  mechanism, because the name *is* the hierarchy.
- **Rename in place** (edit the leaf segment) MUST be available and is the same operation.
- **Name conflicts:** if a move or rename would produce a name that already exists, the
  operation is **blocked with an error** naming the conflicting filter; nothing is renamed.
  A branch move MUST be validated for every filter in the subtree *before* the first rename
  is sent, so a conflict can never leave the branch half-moved.
- Deleting a filter from the sidebar MUST require confirmation and use
  `FiltersService.delete`.

### 2.4 Selection

Selecting a filter in either section loads it into the content area. Selection is
single-item.

Switching the selected filter MUST close the query editor (§3.3) if it is open. An open
editor belongs to the filter it was opened for; leaving it open (and, worse, leaving Apply
able to save) against a query the user has since navigated away from would silently edit the
wrong filter.

---

## 3. Content area

The content area shows the issues matched by the selected filter, in one of **two view
modes**, with a persistent per-filter choice. A toolbar switcher toggles between them.

### 3.1 Table view

- A classic grid: **one thin row per issue**, standard list-row height for the platform
  (terminal: one text line per issue).
- Columns are **configurable**: the user can add, remove, and reorder columns from the
  site's full field list. The configuration maps to the filter's columns
  (`FiltersService.columns/setColumns`), so it travels with the filter, not the client. A
  filter with no columns configured falls back to a fixed default set — configuring never
  changes what a filter shows until the user actually asks it to.
- Cells are **editable**, in v1 for **basic field types only**: text, single-choice fields
  (status via `IssueService.transition`, priority, assignee), labels, and fix versions.
  Complex custom fields render read-only until a later revision. Edits go through
  `IssueService`; failures surface the core's error text and revert the cell.
- Fix versions editing is a **multi-select checklist** against the issue's project's actual
  version list (`ReferenceService.projectVersions`), not free text — an id is unambiguous
  where a typed name could collide across projects, and a checklist can't produce a version
  that doesn't exist. Because a project's version list can be very large, the picker MUST
  offer type-to-filter search, MAY cap the number of rendered options, and MUST keep
  already-selected options visible (e.g. sorted first) regardless of any cap or search filter,
  so a chosen version can never silently fall out of view.
- Any field value that **is or contains a reference to another issue** — linked issues,
  sub-tasks, parent, epic link, and similarly shaped fields — MUST render its issue key as a
  clickable link to that issue, the same treatment the Key column itself gets, rather than as
  inert text. This applies uniformly to whatever field happens to carry the reference; clients
  MUST NOT hardcode a fixed list of which field ids get it.
- **Sorting** is a toolbar control (field + direction), not click-a-header-only, because the
  split view needs it too (§3.2) — both views share one sort state. It is expressed as an
  `ORDER BY` appended to the filter's own JQL for the request (`filter = <id> ORDER BY …`); it
  is never written back to the stored filter as a side effect of merely sorting. **Default:
  `updated`, descending.** Opening the query editor (§3.3) folds the active sort into the JQL
  shown there, so it can be persisted deliberately — sort, open Edit query, Apply — but nothing
  is saved until that explicit Apply.
- **Grouping** (toolbar: a field to group by, or None) buckets the currently loaded issues by
  that field's value and inserts a header row per bucket, in both view modes. This is a
  client-side presentation grouping over the loaded page — Jira's search API has no `GROUP
  BY` — not a second server-side query.

### 3.2 Split view

- Shares the sort and group controls with the table view (§3.1) — same toolbar state,
  applied to the issue list on the left.
- Two panes inside the content area, mirroring a classic three-pane mail client:
  - **Left: the issue list.** One **thick row** per issue — a multi-line cell showing at
    least key, summary, status, and assignee (terminal: several text lines per issue).
    The list is **read-only**; clicking selects, nothing edits.
  - **Right: the issue page.** An embedded web view showing the selected issue's actual
    Jira page, fully interactive — **all editing in split view happens here**, in Jira's
    own UI. Platforms that cannot embed a web view (terminal) MUST show a read-only issue
    rendering in the right pane and offer opening the issue in the system browser.
- Row-height rule holds across implementations: table rows thin, split-list rows thick.

### 3.3 Query editor

- A toolbar **Edit query** action opens the editor for the selected filter's JQL.
- Presentation: a panel that **slides down from the top of the window** with the platform's
  standard animation (macOS: a sheet), containing the query input and an Apply / Cancel
  action pair.
- The JQL is displayed **formatted, with basic syntax highlighting** (keywords, fields,
  operators, strings distinguishable).
- Apply validates through `JQLService.validate` first; validation errors are shown inline in
  the panel and block saving. Saving uses `FiltersService.update`.
- The editor SHOULD offer **completion suggestions** while typing, backed by `JQLService`:
  field and function names (`autocompleteData`) for the token being typed, and field values
  (`suggestions`) once the caret sits after a comparison operator. Suggestions appear in a
  list anchored at the caret, navigable by keyboard (arrows to move, Tab/Enter to accept,
  Escape to dismiss) as well as pointer. Values Jira returns pre-quoted are inserted as-is;
  unquoted multi-word values are quoted on insertion.
- **Keyboard shortcuts**, all scoped so they never fight ordinary typing: with the JQL input
  focused and no completion list open, Ctrl+Enter (Cmd+Enter on macOS) MUST apply, and Escape
  MUST cancel — matching the panel's own Apply/Cancel actions. Plain Enter remains a literal
  newline in the input, since JQL routinely spans multiple lines. Additionally, pressing Space
  while a filter is selected and no field anywhere in the window has keyboard focus SHOULD
  open the editor for it, as a faster path than reaching for the toolbar button.

#### 3.3.1 Filter references

- A `filter = <id>` clause referencing a filter the user can resolve MUST be presented as a
  **coloured, clickable reference chip showing that filter's name**, not its raw numeric id.
  The underlying JQL text is unaffected — the chip is a rendering of the clause, not a
  replacement for it.
- Clicking the chip MUST offer a way to **change which filter it references** — a
  search-by-name picker is sufficient. Selecting a different filter rewrites only that
  clause's id.
- **⌘-clicking (macOS) / Ctrl-clicking (Windows, Linux) the chip MUST navigate to the
  referenced filter itself** — closing the query editor and selecting that filter, the same
  as clicking it in the sidebar. This mirrors the platform's own "follow this reference"
  convention (open link in a new tab, jump to definition), which is the closer match to what
  the gesture does here than Shift (range selection) or Option/Alt (no consistent meaning
  across macOS apps). This is how a chip doubles as a link into
  the filter it points to, not only a way to change what it points to.
- **Dragging a filter from the sidebar into the query editor** MUST insert a `filter = <id>`
  reference for it, which then renders as the same chip described above. This is the
  sidebar-to-editor path the chip mechanism exists to support. The reference is inserted as a
  new top-level condition, joined to whatever conditions already exist rather than always
  appended blindly:
  - No connective at all if the query is currently empty — this is the first condition.
  - `OR` if any of the query's existing **top-level** conditions is already joined by `OR`
    (a connective inside a parenthesized group doesn't count — it joins that group's own
    sub-conditions, not the outer query).
  - `AND` otherwise (including the common case of a single existing condition, or several
    already joined by `AND`).

  Always choosing `AND` regardless of the existing connectives would silently change the
  meaning of an `OR`-based query. The condition is inserted immediately before a trailing
  `ORDER BY` clause if one is present, never after it, regardless of where in the editor the
  drop itself occurred — a dropped reference must never end up split across the sort clause.
- Implementations MAY render the chip inline within the query text (true block editing) or
  as an adjacent element associated with the clause (e.g. a strip beneath the text input) —
  whichever a given platform's text-editing primitives support without fighting them. Both
  satisfy this section; inline rendering is not required where it would mean reimplementing
  text editing from scratch.
- **Future (not in scope now):** extending the same treatment to other JQL constructs
  (fields, values, functions) as fully editable coloured blocks. This document only reserves
  that intent; nothing about it beyond filter references is normative yet.

### 3.4 Freshness

Wherever the core returns `Cached<T>`, the client MUST distinguish live data from cached:
data served from cache is labelled with its age (e.g. "as of 12:04"), and stale data is
visually distinct. Clients MUST NOT present cached data as current.

---

## 4. Cross-implementation notes

| Implementation | Notes |
|---|---|
| macOS (AppKit) | Canonical. Sheet for the query editor, `WKWebView` for the issue pane. |
| Terminal (SwiftTUI) | Same layout in cells: sidebar pane, list/table pane. Split view's right pane is a read-only render + "open in browser". |
| GNUstep | Follows the macOS structure with GNUstep equivalents. |
| Windows (WinUI) | Same structure; WebView2 for the issue pane. |
| Web | The application serves HTTP on localhost; the browser UI implements this same
  specification. The web client talks to the same core (via the serving process), not to
  Jira directly. |

Platform idiom wins on *how* (animations, fonts, controls); this specification wins on
*what* (regions, sections, view modes, row metrics, edit rules, freshness labelling).

---

## 5. Out of scope (this revision)

- The block-based structured JQL editor (§3.3, future note).
- Multiple windows, tabs, or multi-account UI.
- Issue creation from the table view.
- Editing of complex custom field types in the table view (basic types only in v1, §3.1).
- Notifications, background refresh scheduling.

import Foundation

/// The browser UI, embedded as a single self-contained page.
///
/// Embedded rather than shipped as a resource file so the executable is one artifact with no
/// bundle-lookup differences between platforms. No external assets: the page must work with
/// nothing but this server reachable.
enum WebUI {
    static let indexHTML = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Swira</title>
<style>
  :root {
    /* This page is light-only for now. Without this, a browser with dark mode enabled
       force-inverts the page's colors on the assumption that an undeclared page might be
       dark-mode-unaware — turning our actual white background into a near-black one, despite
       every color below being explicitly set. */
    color-scheme: light;
    --sidebar-bg: #f2f1ec; --border: #d9d7d0; --accent: #4a6da7; --accent-soft: #eef2f9;
    --text: #2b2a27; --muted: #8a887f; --row-hover: #f7f6f2; --selected: #dde6f3;
    --stale: #b58a3c; --error: #a04545;
  }
  * { box-sizing: border-box; margin: 0; }
  body {
    font: 13px/1.45 -apple-system, "Segoe UI", system-ui, sans-serif;
    color: var(--text); height: 100vh; display: flex; overflow: hidden; background: #fff;
  }

  /* Sidebar (spec §2) */
  #sidebar {
    width: 240px; min-width: 180px; background: var(--sidebar-bg);
    border-right: 1px solid var(--border); display: flex; flex-direction: column;
    overflow-y: auto; padding: 8px 0; flex-shrink: 0;
  }
  .section-title {
    font-size: 11px; font-weight: 600; letter-spacing: .06em; color: var(--muted);
    text-transform: uppercase; padding: 10px 14px 4px;
    display: flex; align-items: center; justify-content: space-between;
  }
  .section-title button {
    border: 0; background: none; color: var(--muted); cursor: pointer;
    font-size: 12px; padding: 0 2px; line-height: 1;
  }
  .section-title button:hover { color: var(--text); }
  .section-title button.spinning { animation: spin .6s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .side-item {
    padding: 3px 14px; cursor: default; white-space: nowrap; overflow: hidden;
    text-overflow: ellipsis; border-radius: 5px; margin: 0 6px;
  }
  .side-item:hover { background: var(--row-hover); }
  .side-item.selected { background: var(--selected); }
  .side-item.virtual { color: var(--muted); }
  .side-item .star { color: #d9a514; margin-right: 4px; }
  .twisty { display: inline-block; width: 12px; color: var(--muted); cursor: pointer; }
  #sidebar-footer { margin-top: auto; padding: 8px 12px; }
  #btn-new {
    border: 1px solid var(--border); background: #fff; border-radius: 6px;
    padding: 3px 10px; cursor: pointer; font-size: 13px;
  }

  /* Main column */
  #main { flex: 1; display: flex; flex-direction: column; min-width: 0; position: relative; }
  #toolbar {
    display: flex; align-items: center; gap: 10px; padding: 8px 12px;
    border-bottom: 1px solid var(--border); background: #fafaf8; z-index: 2;
  }
  #filter-title { font-weight: 600; margin-right: auto; overflow: hidden;
    white-space: nowrap; text-overflow: ellipsis; }
  .seg { display: inline-flex; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
  .seg button { border: 0; background: #fff; padding: 3px 12px; cursor: pointer; font-size: 12px; }
  .seg button.active { background: var(--accent); color: #fff; }
  #btn-edit-jql, #btn-delete, #btn-columns, #btn-sort-dir {
    border: 1px solid var(--border); background: #fff; border-radius: 6px;
    padding: 3px 10px; cursor: pointer; font-size: 12px;
  }
  #btn-sort-dir { padding: 3px 8px; font-size: 13px; }
  #freshness { font-size: 11px; color: var(--muted); }
  #freshness.stale { color: var(--stale); font-weight: 600; }
  .toolbar-control {
    display: flex; align-items: center; gap: 5px; font-size: 12px; color: var(--muted);
  }
  .toolbar-control select {
    border: 1px solid var(--border); border-radius: 6px; padding: 3px 6px;
    font-size: 12px; background: #fff; color: var(--text);
  }

  /* Table view: generic, configurable columns */
  .col-menu-btn {
    border: 0; background: none; color: var(--muted); cursor: pointer; font-size: 10px;
    padding: 0 2px; visibility: hidden;
  }
  th:hover .col-menu-btn { visibility: visible; }
  .group-header {
    background: var(--sidebar-bg); font-weight: 600; font-size: 12px;
    padding: 5px 10px; border-bottom: 1px solid var(--border); border-top: 1px solid var(--border);
  }
  td.editable { cursor: text; position: relative; }
  td.editable:hover { background: var(--accent-soft); }
  .floating-picker {
    /* `top`/`left` are set in JS via `positionFloatingPicker`, in the viewport's own fixed
       coordinate space — the one case a `<td>`-relative `position: absolute` reliably escapes. */
    position: fixed; z-index: 20; background: #fff;
    border: 1px solid var(--border); border-radius: 8px; box-shadow: 0 8px 24px rgba(0,0,0,.15);
    padding: 4px; min-width: 180px; max-height: 200px; overflow-y: auto;
  }
  .floating-picker .option {
    padding: 5px 7px; border-radius: 5px; cursor: pointer; font-size: 12px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .floating-picker .option:hover, .floating-picker .option.active { background: var(--row-hover); }
  .version-option {
    display: flex; align-items: center; gap: 6px; cursor: pointer; white-space: nowrap;
  }
  .version-option input { margin: 0; }
  /* A project's version list can run into the hundreds — the search box and Apply button stay
     put while only the checklist between them scrolls, so both are always reachable. */
  #version-picker {
    display: flex; flex-direction: column; max-height: 320px; padding: 0; overflow: hidden;
  }
  #version-picker .version-search {
    margin: 6px 6px 4px; padding: 5px 7px; font: inherit; font-size: 12px;
    border: 1px solid var(--border); border-radius: 5px; flex: none;
  }
  #version-picker .version-list {
    overflow-y: auto; padding: 0 4px; flex: 1 1 auto; min-height: 0;
  }
  .version-more {
    cursor: default; color: var(--muted); font-style: italic;
  }
  .version-more:hover { background: none; }
  #version-picker .version-picker-actions { flex: none; margin-top: 0; }
  .version-picker-actions {
    display: flex; justify-content: flex-end; padding: 4px 2px 2px; margin-top: 2px;
    border-top: 1px solid var(--border);
  }
  .version-picker-actions button {
    border: 1px solid var(--accent); background: var(--accent); color: #fff; border-radius: 5px;
    padding: 3px 12px; font-size: 12px; cursor: pointer;
  }
  .cell-editor { width: 100%; font: inherit; border: 1px solid var(--accent); border-radius: 4px;
    padding: 1px 4px; }
  .cell-editor select { width: 100%; }
  .cell-saving { opacity: .5; }
  .cell-error { outline: 1px solid var(--error); }

  /* Columns dialog */
  #columns-current { display: flex; flex-direction: column; gap: 2px; margin: 8px 0; max-height: 200px; overflow-y: auto; }
  .column-row {
    display: flex; align-items: center; gap: 6px; padding: 4px 6px; border: 1px solid var(--border);
    border-radius: 5px; background: #fafaf8; cursor: grab;
  }
  .column-row .handle { color: var(--muted); }
  .column-row .name { flex: 1; }
  .column-row .remove { border: 0; background: none; color: var(--muted); cursor: pointer; font-size: 14px; }
  .column-row .remove:hover { color: var(--error); }
  #columns-add-results { max-height: 140px; overflow-y: auto; margin-top: 4px; }
  #columns-add-results .option { padding: 4px 7px; border-radius: 5px; cursor: pointer; font-size: 12px; }
  #columns-add-results .option:hover { background: var(--row-hover); }

  /* Query editor: the top slide-down panel (spec §3.3) */
  #query-panel {
    position: absolute; top: 0; left: 0; right: 0; z-index: 5;
    background: #fbfaf7; border-bottom: 1px solid var(--border);
    box-shadow: 0 6px 16px rgba(0,0,0,.08);
    transform: translateY(-100%); transition: transform .22s ease; padding: 12px;
  }
  #query-panel.open { transform: translateY(0); }
  #jql-wrap { position: relative; font: 13px/1.6 ui-monospace, Consolas, monospace; }

  /* The JQL editor is a live contenteditable surface, not a textarea: `filter = <id>`
     clauses render as real inline chip elements — atomic, clickable, part of the text flow —
     rather than a separate overlay or a strip below the text (spec §3.3.1). */
  #jql-editor {
    min-height: 64px; max-height: 260px; overflow-y: auto; padding: 8px;
    border: 1px solid var(--border); border-radius: 6px; white-space: pre-wrap;
    word-wrap: break-word; outline: none; background: #fff; color: var(--text);
  }
  #jql-editor:focus { border-color: var(--accent); }
  #jql-editor.drop-target { outline: 2px dashed var(--accent); outline-offset: 2px; }
  .kw { color: #8231a7; font-weight: 600; } .fn { color: #1a66a0; }
  .str { color: #9c5b1d; } .num { color: #1a7a4a; }
  .filter-chip {
    display: inline-flex; align-items: center; gap: 4px; background: var(--accent-soft);
    color: var(--accent); border: 1px solid #c9d7ec; border-radius: 999px;
    padding: 1px 9px 1px 7px; font-size: 12.5px; cursor: pointer; user-select: none;
    vertical-align: baseline; white-space: nowrap;
  }
  .filter-chip:hover { background: #e2eaf6; }
  .filter-chip .caret { font-size: 9px; opacity: .7; }
  #query-errors { color: var(--error); font-size: 12px; margin-top: 6px; white-space: pre-line; }
  #query-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 8px; }
  #query-actions button {
    border: 1px solid var(--border); border-radius: 6px; padding: 4px 14px;
    cursor: pointer; background: #fff; font: inherit; font-size: 13px; color: var(--text);
  }
  #btn-jql-ok {
    background: var(--accent); color: #ffffff; border-color: var(--accent); font-weight: 600;
  }

  /* Content: table view (thin rows, spec §3.1) */
  #content { flex: 1; display: flex; min-height: 0; }
  #table-view { flex: 1; overflow: auto; }
  table { border-collapse: collapse; width: 100%; }
  th { text-align: left; font-size: 11px; color: var(--muted); font-weight: 600;
    padding: 4px 10px; border-bottom: 1px solid var(--border); position: sticky; top: 0;
    background: #fff; }
  td { padding: 3px 10px; border-bottom: 1px solid #eee; white-space: nowrap;
    overflow: hidden; text-overflow: ellipsis; max-width: 420px; }
  tr:hover td { background: var(--row-hover); }
  td.key a { color: var(--accent); text-decoration: none; }

  /* Content: split view (thick rows, spec §3.2) */
  #split-view { flex: 1; display: flex; min-height: 0; }
  #issue-list { width: 340px; min-width: 260px; overflow-y: auto;
    border-right: 1px solid var(--border); flex-shrink: 0; }
  .issue-cell { padding: 8px 12px; border-bottom: 1px solid #eee; cursor: default; }
  .issue-cell:hover { background: var(--row-hover); }
  .issue-cell.selected { background: var(--selected); }
  .issue-cell .top { display: flex; justify-content: space-between; gap: 8px; }
  .issue-cell .key { font-weight: 600; color: var(--accent); font-size: 12px; }
  .issue-cell .status { font-size: 11px; color: var(--muted); }
  .issue-cell .summary { margin: 2px 0; overflow: hidden; display: -webkit-box;
    -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
  .issue-cell .who { font-size: 11px; color: var(--muted); }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 5px; }
  .dot.new { background: #7a9bd4; } .dot.indeterminate { background: #e0b33c; }
  .dot.done { background: #58a072; }
  #issue-pane { flex: 1; display: flex; flex-direction: column; min-width: 0; }
  #issue-pane-bar { padding: 6px 10px; border-bottom: 1px solid var(--border);
    display: flex; gap: 10px; align-items: center; font-size: 12px; }
  #issue-pane-bar a { color: var(--accent); }
  #issue-frame { flex: 1; border: 0; width: 100%; }
  .placeholder { color: var(--muted); padding: 40px; text-align: center; flex: 1; }

  /* Dialogs, banner */
  #banner { background: #f9edd7; border-bottom: 1px solid #e5cf9d; color: #6d5316;
    padding: 8px 14px; font-size: 12px; display: none; }
  dialog { border: 1px solid var(--border); border-radius: 10px; padding: 16px;
    min-width: 380px; box-shadow: 0 12px 40px rgba(0,0,0,.18); }
  /* Anchored dialogs (spec: opened near the button that triggered them, not centered in a
     possibly much larger window) override the UA stylesheet's `margin: auto` centering with an
     explicit position set in JS before showModal(). */
  dialog.anchored { margin: 0; }
  dialog::backdrop { background: rgba(0,0,0,.2); }
  dialog label { display: block; font-size: 12px; color: var(--muted); margin: 10px 0 3px; }
  dialog input, dialog textarea { width: 100%; padding: 6px; border: 1px solid var(--border);
    border-radius: 6px; font: inherit; }
  dialog .actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 14px; }
  dialog .actions button { border: 1px solid var(--border); border-radius: 6px;
    padding: 4px 14px; cursor: pointer; background: #fff; }
  dialog .actions .primary { background: var(--accent); color: #fff; border-color: var(--accent); }
  .dialog-error { color: var(--error); font-size: 12px; margin-top: 8px; }

  /* Filter-reference picker popover (spec §3.3.1) */
  .side-item[draggable="true"] { cursor: grab; }
  #chip-popover {
    position: absolute; z-index: 10; background: #fff; border: 1px solid var(--border);
    border-radius: 8px; box-shadow: 0 8px 24px rgba(0,0,0,.15); padding: 6px; width: 220px;
    display: none;
  }
  #chip-popover input { width: 100%; padding: 5px 7px; border: 1px solid var(--border);
    border-radius: 6px; font-size: 12px; margin-bottom: 4px; }
  #chip-popover .option { padding: 5px 7px; border-radius: 5px; cursor: pointer; font-size: 12px;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  #chip-popover .option:hover { background: var(--row-hover); }
  #chip-popover .empty { padding: 5px 7px; color: var(--muted); font-size: 12px; }
</style>
</head>
<body>
  <aside id="sidebar">
    <div class="section-title">
      <span>Favourites</span>
      <button id="btn-refresh-sidebar" title="Refresh from Jira">⟳</button>
    </div>
    <div id="favourites"></div>
    <div class="section-title"><span>Filters</span></div>
    <div id="tree"></div>
    <div id="sidebar-footer"><button id="btn-new">＋ New filter</button></div>
  </aside>

  <div id="main">
    <div id="banner"></div>
    <div id="query-panel">
      <div id="jql-wrap">
        <div id="jql-editor" contenteditable="true" spellcheck="false"></div>
      </div>
      <div id="query-errors"></div>
      <div id="query-actions">
        <button id="btn-jql-cancel">Cancel</button>
        <button id="btn-jql-ok">Apply</button>
      </div>
    </div>

    <div id="toolbar">
      <span id="filter-title">Select a filter</span>
      <span id="freshness"></span>
      <div class="seg">
        <button id="btn-table" class="active">Table</button>
        <button id="btn-split">Split</button>
      </div>
      <label class="toolbar-control">Sort
        <select id="sort-field"></select>
      </label>
      <button id="btn-sort-dir" class="toolbar-control" title="Toggle sort direction">↓</button>
      <label class="toolbar-control">Group by
        <select id="group-field"><option value="">None</option></select>
      </label>
      <button id="btn-columns" disabled>Columns…</button>
      <button id="btn-edit-jql" disabled>Edit query</button>
      <button id="btn-delete" disabled>Delete</button>
    </div>

    <div id="content">
      <div id="table-view"><div class="placeholder">Choose a filter in the sidebar.</div></div>
      <div id="split-view" style="display:none">
        <div id="issue-list"></div>
        <div id="issue-pane">
          <div id="issue-pane-bar" style="display:none">
            <span id="issue-pane-key"></span>
            <a id="issue-pane-open" target="_blank" rel="noopener">Open in Jira ↗</a>
          </div>
          <iframe id="issue-frame" style="display:none"></iframe>
          <div class="placeholder" id="issue-pane-placeholder">Select an issue.</div>
        </div>
      </div>
    </div>
  </div>

  <div id="chip-popover">
    <input id="chip-search" placeholder="Search filters…">
    <div id="chip-options"></div>
  </div>

  <!-- A page-level element rather than a child of the table cell: a `position: absolute`
       popover nested inside a `<td>` does not reliably paint above sibling table rows in every
       browser's table-layout stacking, even with an explicit z-index (reproduced live —
       the element existed in the DOM with correct, "visible" computed styles, and simply never
       rendered on screen). Positioned in JS with `position: fixed` before each use. -->
  <div id="assignee-picker" class="floating-picker" style="display:none"></div>
  <!-- Same page-level treatment, for the same table-stacking reason — though this one lives
       over the (non-table) query editor, it's positioned the same way for consistency and
       because caret-relative positioning needs the same viewport-fixed math regardless. -->
  <div id="jql-autocomplete" class="floating-picker" style="display:none"></div>
  <div id="version-picker" class="floating-picker" style="display:none"></div>

  <dialog id="dlg-new">
    <b>New filter</b>
    <label>Path (segments joined by ": ")</label>
    <input id="new-name" placeholder="Swira: Bugs: Open">
    <label>JQL</label>
    <textarea id="new-jql" rows="3" placeholder="project = X AND status != Done"></textarea>
    <label>Description (optional)</label>
    <input id="new-desc">
    <div class="dialog-error" id="new-error"></div>
    <div class="actions">
      <button id="new-cancel">Cancel</button>
      <button class="primary" id="new-ok">Create</button>
    </div>
  </dialog>

  <dialog id="dlg-columns">
    <b>Table columns</b>
    <div id="columns-current"></div>
    <label>Add a field</label>
    <input id="columns-add-search" placeholder="Search fields…">
    <div id="columns-add-results"></div>
    <div class="dialog-error" id="columns-error"></div>
    <div class="actions">
      <button id="columns-reset">Reset to default</button>
      <button id="columns-cancel">Cancel</button>
      <button class="primary" id="columns-save">Save</button>
    </div>
  </dialog>

<script>
"use strict";
const $ = (id) => document.getElementById(id);
const state = {
  filter: null, view: "table", issues: [], selectedIssue: null,
  columns: [], columnsAreDefault: true, allFields: null,
  sortField: "updated", sortDir: "desc", groupField: "",
};

async function api(path, options) {
  const response = await fetch(path, options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || (data.errors || []).join("; ") || response.statusText);
  return data;
}

/* ---------- Sidebar ---------- */

async function loadSidebar(fresh) {
  const button = $("btn-refresh-sidebar");
  if (fresh) button.classList.add("spinning");
  try {
    const data = await api(fresh ? "/api/sidebar?fresh=1" : "/api/sidebar");
    renderFavourites(data.favourites);
    renderTree(data.tree);
  } catch (error) {
    showBanner(error.message);
  } finally {
    button.classList.remove("spinning");
  }
}

function renderFavourites(favourites) {
  const host = $("favourites");
  host.innerHTML = "";
  for (const filter of favourites) {
    const row = document.createElement("div");
    row.className = "side-item";
    row.dataset.filterId = filter.id;
    // Full name, never just the leaf (spec §2.1).
    row.innerHTML = `<span class="star">★</span>${escapeHTML(filter.name)}`;
    row.onclick = () => selectFilter(filter);
    makeDraggableFilterSource(row, filter);
    host.appendChild(row);
  }
}

/// Sidebar → query editor drag source (spec §3.3.1): dropping this row into the query
/// editor inserts a `filter = <id>` reference for it.
function makeDraggableFilterSource(row, filter) {
  row.draggable = true;
  row.ondragstart = (event) => {
    event.dataTransfer.setData("application/x-swira-filter", JSON.stringify(filter));
    event.dataTransfer.setData("text/plain", filter.name);
    event.dataTransfer.effectAllowed = "copy";
  };
  // Known ahead of any lookup — primes the chip cache so a dropped reference renders its
  // name immediately, with no round trip.
  filterNamesById[filter.id] = filter.name;
}

// Which sidebar groups are collapsed, keyed by their full path (`node.path` — stable across
// reloads, unlike a DOM reference) — persisted so the tree looks the same after a refresh
// instead of resetting to fully expanded every time.
const COLLAPSED_GROUPS_KEY = "swira.collapsedGroups";

function loadCollapsedGroups() {
  try {
    return new Set(JSON.parse(localStorage.getItem(COLLAPSED_GROUPS_KEY) || "[]"));
  } catch {
    return new Set();
  }
}

function saveCollapsedGroups(collapsed) {
  try {
    localStorage.setItem(COLLAPSED_GROUPS_KEY, JSON.stringify([...collapsed]));
  } catch {
    // Storage can be unavailable (private browsing, quota) — collapse state just won't persist.
  }
}

function renderTree(nodes) {
  const host = $("tree");
  host.innerHTML = "";
  const collapsed = loadCollapsedGroups();
  const renderLevel = (items, depth, container) => {
    for (const node of items) {
      const row = document.createElement("div");
      row.className = "side-item" + (node.filter ? "" : " virtual");
      row.style.paddingLeft = `${14 + depth * 14}px`;
      const isCollapsed = node.children.length > 0 && collapsed.has(node.path);
      const twisty = node.children.length ? (isCollapsed ? "▸" : "▾") : "";
      row.innerHTML = `<span class="twisty">${twisty}</span>${escapeHTML(node.name)}`;
      if (node.filter) {
        row.dataset.filterId = node.filter.id;
        row.onclick = () => selectFilter(node.filter);
        makeDraggableFilterSource(row, node.filter);
      }
      container.appendChild(row);
      if (node.children.length) {
        const childBox = document.createElement("div");
        childBox.style.display = isCollapsed ? "none" : "";
        container.appendChild(childBox);
        renderLevel(node.children, depth + 1, childBox);
        row.querySelector(".twisty").onclick = (event) => {
          event.stopPropagation();
          const hidden = childBox.style.display === "none";
          childBox.style.display = hidden ? "" : "none";
          row.querySelector(".twisty").textContent = hidden ? "▾" : "▸";
          if (hidden) collapsed.delete(node.path); else collapsed.add(node.path);
          saveCollapsedGroups(collapsed);
        };
      }
    }
  };
  renderLevel(nodes, 0, host);
}

function selectFilter(filter) {
  // An open query editor belongs to the filter it was opened for — switching filters out from
  // under it would leave the editor showing (and, on Apply, ready to save) the wrong filter's
  // query.
  $("query-panel").classList.remove("open");
  state.filter = filter;
  state.selectedIssue = null;
  document.querySelectorAll(".side-item.selected").forEach((el) => el.classList.remove("selected"));
  document.querySelectorAll(`.side-item[data-filter-id="${CSS.escape(filter.id)}"]`)
    .forEach((el) => el.classList.add("selected"));
  $("filter-title").textContent = filter.name;
  $("btn-edit-jql").disabled = false;
  $("btn-delete").disabled = false;
  $("btn-columns").disabled = false;
  loadIssues();
}

/* ---------- Issues ---------- */

async function loadIssues() {
  if (!state.filter) return;
  try {
    const detail = await api(`/api/filter/${encodeURIComponent(state.filter.id)}`);
    state.filter = detail.filter;
    renderFreshness(detail.meta);

    const params = new URLSearchParams({ limit: "50" });
    if (state.sortField) {
      params.set("sortField", state.sortField);
      params.set("sortDir", state.sortDir);
    }
    const data = await api(`/api/filter/${encodeURIComponent(state.filter.id)}/issues?${params}`);
    state.issues = data.issues;
    if (data.issues[0]) {
      // Every issue carries its own `browseUrl`; derive the shared site base from one of them
      // rather than adding a dedicated endpoint just for a prefix.
      state.browseBase = data.issues[0].browseUrl.replace(/\/browse\/.*$/, "");
    }
    state.columns = data.columns;
    state.columnsAreDefault = data.columnsAreDefault;
    populateSortAndGroupOptions();
    renderContent();
  } catch (error) {
    showBanner(error.message);
  }
}

function renderFreshness(meta) {
  const el = $("freshness");
  el.title = "";
  if (!meta || meta.origin === "network") { el.textContent = "live"; el.className = ""; return; }
  if (meta.storedAt) {
    const date = new Date(meta.storedAt);
    el.textContent = `cached · ${relativeTime(date)}`;
    // Relative time is the readable label; the exact timestamp is one hover away rather than
    // discarded outright.
    el.title = date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });
  } else {
    el.textContent = "cached";
  }
  el.className = meta.isStale ? "stale" : "";
}

function renderContent() {
  $("table-view").style.display = state.view === "table" ? "" : "none";
  $("split-view").style.display = state.view === "split" ? "flex" : "none";
  $("btn-table").classList.toggle("active", state.view === "table");
  $("btn-split").classList.toggle("active", state.view === "split");
  if (state.view === "table") renderTable(); else renderSplit();
}

/* ----- Rendering an arbitrary Jira field value, and grouping by one ----- */

/// Jira field values arrive in a handful of common shapes: a plain scalar, an array (labels),
/// or an object carrying `.displayName`/`.name`/`.value`/`.key` (user, status, priority,
/// select-list, project). Covers what the configured columns realistically hold without
/// needing a renderer per field type.
// Jira's own timestamp shape: "2026-03-14T09:41:00.000+0000" — with the leading anchors this
// won't false-match plain text that merely contains a similar-looking substring.
// Jira's full timestamp shape: "2026-03-14T09:41:00.000+0000". A bare date (no time) — e.g.
// `duedate` — arrives separately as "2026-03-14"; both need their own pretty-printing, since
// neither is what a user should read raw.
const JIRA_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{4}$/;
const JIRA_DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

/// "just now" / "5m ago" / "3h ago" / "6d ago", falling back to an absolute date once a value
/// is old enough that "N days ago" stops being more useful than the date itself.
function relativeTime(date) {
  const seconds = Math.round((Date.now() - date.getTime()) / 1000);
  if (seconds < 0) return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  if (seconds < 45) return "just now";
  if (seconds < 90) return "a minute ago";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 14) return `${days}d ago`;
  return date.toLocaleDateString(undefined, { dateStyle: "medium" });
}

/// An issue key on its own, e.g. `${browseBase}/browse/SW-123` — the same link the Key column
/// uses, so a key means the same clickable thing everywhere it shows up.
function issueKeyLink(key) {
  const href = state.browseBase ? `${state.browseBase}/browse/${encodeURIComponent(key)}` : null;
  return href
    ? `<a href="${href}" target="_blank" rel="noopener">${escapeHTML(key)}</a>`
    : escapeHTML(key);
}

/// Jira's own key format: `PROJECT-123`. Used to spot fields (parent, epic link, and similar
/// `{key: "..."}` objects) whose value is itself an issue reference worth linking, without
/// hardcoding a list of field ids.
const ISSUE_KEY_PATTERN = /^[A-Za-z][A-Za-z0-9_]*-\d+$/;

/// An `issuelinks` entry: `{type: {inward, outward}, inwardIssue|outwardIssue: {key, fields}}`.
/// None of its top-level keys are `displayName`/`name`/`value`/`key`, so the generic object
/// fallback below renders it as nothing — this is why linked issues showed up blank.
function renderIssueLink(value) {
  const linked = value.outwardIssue || value.inwardIssue;
  if (!linked || !value.type) return null;
  const verb = value.outwardIssue ? value.type.outward : value.type.inward;
  const summary = linked.fields?.summary ? `: ${escapeHTML(linked.fields.summary)}` : "";
  return `${escapeHTML(verb ?? "linked to")} ${issueKeyLink(linked.key)}${summary}`;
}

// Jira's REST API always reports time-tracking fields as a raw integer of seconds — "1h" in
// the Jira UI arrives here as `3600` — regardless of the project's working-hours configuration.
const DURATION_FIELD_IDS = new Set([
  "timespent", "timeestimate", "timeoriginalestimate",
  "aggregatetimespent", "aggregatetimeestimate", "aggregatetimeoriginalestimate",
]);

/// `3600` → `"1h"`. Deliberately hours/minutes only, never "days" — a Jira "day" is a
/// configurable work-day length (often 8h), which this client has no way to know, so assuming
/// a specific value (like the real 24h) would just be a different kind of wrong.
function formatDuration(totalSeconds) {
  const sign = totalSeconds < 0 ? "-" : "";
  const seconds = Math.round(Math.abs(totalSeconds));
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  if (hours === 0 && minutes === 0) return "0m";
  return sign + [hours ? `${hours}h` : null, minutes ? `${minutes}m` : null]
    .filter(Boolean).join(" ");
}

/// `fieldId` is optional context for values that can't be told apart from their shape alone —
/// a raw number is meaningless without knowing which field it came from. Plain text: safe for
/// grouping keys and anywhere else HTML markup would be wrong, but never for direct `innerHTML`
/// — use `renderFieldValueHTML` for that.
function renderFieldValue(value, fieldId) {
  if (value === null || value === undefined) return "";
  if (typeof value === "number" && DURATION_FIELD_IDS.has(fieldId)) return formatDuration(value);
  if (Array.isArray(value)) {
    return value.map((v) => renderFieldValue(v, fieldId)).filter(Boolean).join(", ");
  }
  if (typeof value === "object") {
    const linked = value.outwardIssue || value.inwardIssue;
    if (linked && value.type) {
      const verb = value.outwardIssue ? value.type.outward : value.type.inward;
      const summary = linked.fields?.summary ? `: ${linked.fields.summary}` : "";
      return `${verb ?? "linked to"} ${linked.key}${summary}`;
    }
    return value.displayName ?? value.name ?? value.value ?? value.key ?? "";
  }
  if (typeof value === "string" && JIRA_TIMESTAMP.test(value)) {
    const date = new Date(value);
    if (!Number.isNaN(date.getTime())) return relativeTime(date);
  }
  if (typeof value === "string" && JIRA_DATE_ONLY.test(value)) {
    // Midday UTC, not midnight: sidesteps the value rendering as "yesterday" in a timezone
    // west of UTC purely from the date-to-Date conversion, for a field that has no time part.
    const date = new Date(`${value}T12:00:00Z`);
    if (!Number.isNaN(date.getTime())) {
      return date.toLocaleDateString(undefined, { dateStyle: "medium" });
    }
  }
  return String(value);
}

/// Table-cell rendering of a field value, as safe HTML: like `renderFieldValue`, but an issue
/// key found anywhere in the value — a linked issue, a parent, an epic link, or a bare
/// key-shaped string — becomes a clickable link to that issue, the same as the Key column.
function renderFieldValueHTML(value, fieldId) {
  if (value === null || value === undefined) return "";
  if (Array.isArray(value)) {
    return value.map((v) => renderFieldValueHTML(v, fieldId)).filter(Boolean).join(", ");
  }
  if (typeof value === "object") {
    const linkedIssue = renderIssueLink(value);
    if (linkedIssue) return linkedIssue;
    if (typeof value.key === "string" && ISSUE_KEY_PATTERN.test(value.key)) {
      const summary = value.fields?.summary ? `: ${escapeHTML(value.fields.summary)}` : "";
      return `${issueKeyLink(value.key)}${summary}`;
    }
  }
  if (typeof value === "string" && ISSUE_KEY_PATTERN.test(value)) return issueKeyLink(value);
  return escapeHTML(renderFieldValue(value, fieldId));
}

/// Basic field types this v1 can edit inline (spec §3.1) — everything else in a configured
/// column renders read-only. `null` means "not editable."
function editableKindFor(fieldId) {
  if (fieldId === "status") return "status";
  if (fieldId === "priority") return "priority";
  if (fieldId === "assignee") return "assignee";
  if (fieldId === "labels") return "labels";
  if (fieldId === "fixVersions") return "fixVersions";
  if (fieldId === "summary") return "text";
  return null;
}

function groupIssues(issues, groupField) {
  if (!groupField) return [{ label: null, issues }];
  const buckets = new Map();
  for (const issue of issues) {
    const label = renderFieldValue(issue.fields[groupField], groupField) || "(none)";
    if (!buckets.has(label)) buckets.set(label, []);
    buckets.get(label).push(issue);
  }
  return Array.from(buckets.entries())
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([label, groupIssues]) => ({ label, issues: groupIssues }));
}

function populateSortAndGroupOptions() {
  const baseline = [
    { value: "updated", label: "Updated" },
    { value: "created", label: "Created" },
    { value: "priority", label: "Priority" },
    { value: "status", label: "Status" },
    { value: "key", label: "Key" },
  ];
  const seen = new Set();
  const options = [...baseline, ...state.columns].filter((option) => {
    if (seen.has(option.value)) return false;
    seen.add(option.value);
    return true;
  });

  const sortSelect = $("sort-field");
  sortSelect.innerHTML = options
    .map((o) => `<option value="${o.value}">${escapeHTML(o.label)}</option>`).join("");
  sortSelect.value = state.sortField;

  const groupSelect = $("group-field");
  groupSelect.innerHTML = `<option value="">None</option>` + options
    .map((o) => `<option value="${o.value}">${escapeHTML(o.label)}</option>`).join("");
  groupSelect.value = state.groupField;
}

/* ----- Table view: configurable columns, grouping, inline editing ----- */

function renderTable() {
  const host = $("table-view");
  if (!state.issues.length) {
    host.innerHTML = `<div class="placeholder">No issues match this filter.</div>`;
    return;
  }
  const columns = state.columns;
  const groups = groupIssues(state.issues, state.groupField);
  const colCount = columns.length + 1;

  let html = "<table><thead><tr><th>Key</th>"
    + columns.map((c) => `<th>${escapeHTML(c.label)}</th>`).join("") + "</tr></thead><tbody>";

  for (const group of groups) {
    if (group.label !== null) {
      html += `<tr><td class="group-header" colspan="${colCount}">${escapeHTML(group.label)} · ${group.issues.length}</td></tr>`;
    }
    for (const issue of group.issues) {
      html += `<tr><td class="key"><a href="${issue.browseUrl}" target="_blank" rel="noopener">${issue.key}</a></td>`;
      for (const column of columns) {
        const kind = editableKindFor(column.value);
        const raw = issue.fields[column.value];
        const display = column.value === "status"
          ? `<span class="dot ${issue.statusCategory || ""}"></span>${renderFieldValueHTML(raw, column.value)}`
          : renderFieldValueHTML(raw, column.value);
        html += kind
          ? `<td class="editable" data-key="${issue.key}" data-field="${column.value}" data-kind="${kind}">${display}</td>`
          : `<td>${display}</td>`;
      }
      html += "</tr>";
    }
  }
  host.innerHTML = html + "</tbody></table>";
  host.querySelectorAll("td.editable").forEach((cell) => {
    cell.onclick = () => activateCellEditor(cell);
  });
}

function renderSplit() {
  const host = $("issue-list");
  host.innerHTML = "";
  const groups = groupIssues(state.issues, state.groupField);
  for (const group of groups) {
    if (group.label !== null) {
      const header = document.createElement("div");
      header.className = "group-header";
      header.textContent = `${group.label} · ${group.issues.length}`;
      host.appendChild(header);
    }
    for (const issue of group.issues) {
      const cell = document.createElement("div");
      cell.className = "issue-cell" + (state.selectedIssue?.key === issue.key ? " selected" : "");
      cell.innerHTML = `
        <div class="top"><span class="key">${issue.key}</span>
          <span class="status"><span class="dot ${issue.statusCategory || ""}"></span>${escapeHTML(issue.status || "")}</span></div>
        <div class="summary">${escapeHTML(issue.summary || "")}</div>
        <div class="who">${escapeHTML(issue.assignee || "Unassigned")}</div>`;
      cell.onclick = () => { state.selectedIssue = issue; renderSplit(); showIssue(issue); };
      host.appendChild(cell);
    }
  }
}

/* ----- Inline cell editing (spec §3.1: basic field types) ----- */

async function activateCellEditor(cell) {
  // Already mid-edit. `fixVersions`' picker lives outside the cell (same table-stacking reason
  // as the assignee picker), so it marks the cell itself rather than leaving a child to find.
  if (cell.querySelector(".cell-editor, .floating-picker") || cell.classList.contains("editing")) return;
  const key = cell.dataset.key;
  const fieldId = cell.dataset.field;
  const kind = cell.dataset.kind;
  const original = cell.innerHTML;

  function commitOnEnterOrEscape(input, commit) {
    input.onkeydown = (event) => {
      if (event.key === "Enter") { event.preventDefault(); input.blur(); }
      if (event.key === "Escape") { input.onblur = null; cell.innerHTML = original; }
    };
    input.onblur = commit;
  }

  if (kind === "text") {
    cell.innerHTML = `<input class="cell-editor" value="${escapeHTML(cell.textContent)}">`;
    const input = cell.querySelector("input");
    input.focus();
    input.select();
    commitOnEnterOrEscape(input, () =>
      saveCellEdit(cell, key, { kind: "text", fieldId, value: input.value }, original));
    return;
  }

  if (kind === "labels") {
    const current = state.issues.find((i) => i.key === key)?.fields?.labels;
    const currentText = Array.isArray(current) ? current.join(", ") : "";
    cell.innerHTML = `<input class="cell-editor" value="${escapeHTML(currentText)}" placeholder="comma-separated">`;
    const input = cell.querySelector("input");
    input.focus();
    input.select();
    commitOnEnterOrEscape(input, () => {
      const labels = input.value.split(",").map((s) => s.trim()).filter(Boolean);
      saveCellEdit(cell, key, { kind: "labels", labels }, original);
    });
    return;
  }

  if (kind === "fixVersions") {
    // Fix versions are a fixed set of choices per project, not free text like labels — a
    // checklist rather than a comma-separated input, so nothing gets rejected as an
    // unrecognized version name.
    const issue = state.issues.find((i) => i.key === key);
    const projectKey = issue?.fields?.project?.key;
    if (!projectKey) {
      showBanner("Could not determine this issue's project.");
      return;
    }

    cell.classList.add("editing");
    let versions;
    try {
      state.projectVersionsCache ??= {};
      versions = state.projectVersionsCache[projectKey]
        ??= await api(`/api/project/${encodeURIComponent(projectKey)}/versions`);
    } catch (error) {
      cell.classList.remove("editing");
      showBanner(error.message);
      return;
    }

    const currentIds = new Set((issue.fields.fixVersions || []).map((v) => v.id));
    const selected = new Set(currentIds);
    const picker = $("version-picker");

    // A project's fix-versions list can be very long — a search box up top narrows it by
    // keystroke, and the rendered checklist itself is capped (re-filtered from the full,
    // uncapped `versions` array each keystroke) so one giant project doesn't turn every open
    // of this picker into a several-hundred-checkbox layout.
    const MAX_VISIBLE_VERSIONS = 100;

    const renderList = (query) => {
      const list = picker.querySelector(".version-list");
      if (!list) return;
      const q = query.trim().toLowerCase();
      const matches = versions.filter((v) => v.name.toLowerCase().includes(q));
      // Already-selected versions sort first — with a long list capped below, a chosen version
      // must stay visible (and never silently fall off past the cap) rather than depending on
      // where it happens to fall in the project's own ordering.
      matches.sort((a, b) => (selected.has(b.id) ? 1 : 0) - (selected.has(a.id) ? 1 : 0));
      const shown = matches.slice(0, MAX_VISIBLE_VERSIONS);
      list.innerHTML = shown.map((v) => `
          <label class="option version-option">
            <input type="checkbox" value="${v.id}"${selected.has(v.id) ? " checked" : ""}>
            ${escapeHTML(v.name)}${v.released ? "" : " (unreleased)"}
          </label>`).join("")
        + (matches.length > shown.length
            ? `<div class="option version-more">+${matches.length - shown.length} more — keep typing to narrow it down</div>`
            : "");
      list.querySelectorAll('input[type="checkbox"]').forEach((box) => {
        box.onchange = () => { if (box.checked) selected.add(box.value); else selected.delete(box.value); };
      });
    };

    picker.innerHTML = versions.length
      ? `<input type="text" class="version-search" placeholder="Search versions…">`
        + `<div class="version-list"></div>`
        + `<div class="version-picker-actions"><button type="button" class="apply">Apply</button></div>`
      : `<div class="option">No versions in this project.</div>`;

    const searchInput = picker.querySelector(".version-search");
    if (searchInput) {
      renderList("");
      searchInput.oninput = () => renderList(searchInput.value);
      searchInput.focus();
    }

    const finish = () => {
      hideFloatingPicker(picker);
      cell.classList.remove("editing");
      document.removeEventListener("mousedown", onOutsideClick, true);
      document.removeEventListener("keydown", onKeydown, true);
    };
    const onOutsideClick = (event) => {
      if (!picker.contains(event.target) && !cell.contains(event.target)) {
        finish();
        cell.innerHTML = original;
      }
    };
    const onKeydown = (event) => {
      if (event.key === "Escape") { finish(); cell.innerHTML = original; }
    };
    picker.querySelector(".apply").onclick = () => {
      finish();
      saveCellEdit(cell, key, { kind: "fixVersions", versionIds: Array.from(selected) }, original);
    };
    document.addEventListener("mousedown", onOutsideClick, true);
    document.addEventListener("keydown", onKeydown, true);
    positionFloatingPicker(picker, cell);
    return;
  }

  if (kind === "priority") {
    // Captured from `original`, before the cell is overwritten below — reading cell.textContent
    // after that point would see the "Loading…" placeholder instead of the real value.
    const currentName = plainTextOf(original);
    cell.innerHTML = `<select class="cell-editor"><option>Loading…</option></select>`;
    const select = cell.querySelector("select");
    let priorities;
    try {
      priorities = await api("/api/priorities");
    } catch (error) {
      cell.innerHTML = original;
      showBanner(error.message);
      return;
    }
    select.innerHTML = priorities
      .map((p) => `<option value="${p.id}"${p.name === currentName ? " selected" : ""}>${escapeHTML(p.name)}</option>`)
      .join("");
    select.onblur = () => { if (cell.contains(select)) cell.innerHTML = original; };
    select.onchange = () => {
      select.onblur = null;
      saveCellEdit(cell, key, { kind: "priority", priorityId: select.value }, original);
    };
    select.focus();
    return;
  }

  if (kind === "status") {
    cell.innerHTML = `<select class="cell-editor"><option>Loading…</option></select>`;
    const select = cell.querySelector("select");
    let transitions;
    try {
      transitions = await api(`/api/issue/${encodeURIComponent(key)}/transitions`);
    } catch (error) {
      cell.innerHTML = original;
      showBanner(error.message);
      return;
    }
    if (!transitions.length) {
      cell.innerHTML = original;
      showBanner("No transitions are available from this issue's current status.");
      return;
    }
    select.innerHTML = `<option value="">Change status…</option>`
      + transitions.map((t) => `<option value="${t.id}">${escapeHTML(t.name)}</option>`).join("");
    select.onblur = () => { if (cell.contains(select)) cell.innerHTML = original; };
    select.onchange = async () => {
      select.onblur = null;
      if (!select.value) { cell.innerHTML = original; return; }
      cell.classList.add("cell-saving");
      try {
        await api(`/api/issue/${encodeURIComponent(key)}/transitions`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ transitionId: select.value }),
        });
        // A transition can change more than status text — its category, and which
        // transitions are valid next — so a full reload is the only accurate way to reflect it.
        loadIssues();
      } catch (error) {
        cell.innerHTML = original;
        cell.classList.remove("cell-saving");
        showBanner(error.message);
      }
    };
    select.focus();
    return;
  }

  if (kind === "assignee") {
    cell.innerHTML = `<input class="cell-editor" placeholder="Search people…" value="${escapeHTML(cell.textContent)}">`;
    const input = cell.querySelector("input");
    input.focus();
    input.select();
    // The shared, page-level picker (see its HTML comment) — not a child of this cell.
    const picker = $("assignee-picker");
    let searchTimer = null;
    const closePicker = () => hideFloatingPicker(picker);

    input.oninput = () => {
      clearTimeout(searchTimer);
      const query = input.value.trim();
      searchTimer = setTimeout(async () => {
        closePicker();
        if (!query) return;
        let users;
        try {
          users = await api(`/api/users/search?q=${encodeURIComponent(query)}`);
        } catch {
          return;
        }
        picker.innerHTML = users.length ? "" : `<div class="option">No matches.</div>`;
        for (const user of users) {
          const option = document.createElement("div");
          option.className = "option";
          option.textContent = user.displayName;
          // mousedown (not click) fires before the input's blur, so the picker's own blur
          // handler doesn't destroy it first.
          option.onmousedown = (event) => {
            event.preventDefault();
            closePicker();
            saveCellEdit(cell, key, { kind: "assignee", accountId: user.accountId }, original);
          };
          picker.appendChild(option);
        }
        positionFloatingPicker(picker, input);
      }, 200);
    };
    input.onblur = () => {
      setTimeout(() => {
        closePicker();
        if (cell.contains(input)) cell.innerHTML = original;
      }, 150);
    };
    input.onkeydown = (event) => {
      if (event.key === "Escape") { closePicker(); cell.innerHTML = original; }
    };
    return;
  }
}

async function saveCellEdit(cell, key, body, original) {
  cell.classList.add("cell-saving");
  try {
    await api(`/api/issue/${encodeURIComponent(key)}/fields`, {
      method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    loadIssues();
  } catch (error) {
    cell.innerHTML = original;
    cell.classList.add("cell-error");
    setTimeout(() => cell.classList.remove("cell-error"), 1500);
    showBanner(error.message);
  } finally {
    cell.classList.remove("cell-saving");
  }
}

/* ----- Configuring which columns show (spec §3.1) ----- */

let dialogColumns = [];
let dragColumnIndex = null;

async function openColumnsDialog() {
  $("columns-error").textContent = "";
  if (!state.allFields) {
    try {
      state.allFields = await api("/api/fields");
    } catch (error) {
      state.allFields = [];
      showBanner(error.message);
    }
  }
  dialogColumns = state.columns.map((c) => ({ ...c }));
  renderColumnsCurrent();
  $("columns-add-search").value = "";
  $("columns-add-results").innerHTML = "";
  showDialogNear($("dlg-columns"), $("btn-columns"));
}

function renderColumnsCurrent() {
  const host = $("columns-current");
  host.innerHTML = "";
  dialogColumns.forEach((column, index) => {
    const row = document.createElement("div");
    row.className = "column-row";
    row.draggable = true;
    row.innerHTML = `<span class="handle">⠿</span><span class="name">${escapeHTML(column.label)}</span>`
      + `<button class="remove" title="Remove">✕</button>`;
    row.querySelector(".remove").onclick = () => {
      dialogColumns.splice(index, 1);
      renderColumnsCurrent();
    };
    row.ondragstart = () => { dragColumnIndex = index; };
    row.ondragover = (event) => event.preventDefault();
    row.ondrop = (event) => {
      event.preventDefault();
      if (dragColumnIndex === null || dragColumnIndex === index) return;
      const [moved] = dialogColumns.splice(dragColumnIndex, 1);
      dialogColumns.splice(index, 0, moved);
      dragColumnIndex = null;
      renderColumnsCurrent();
    };
    host.appendChild(row);
  });
}

let columnsSearchTimer = null;
function onColumnsSearchInput() {
  clearTimeout(columnsSearchTimer);
  columnsSearchTimer = setTimeout(() => {
    const query = $("columns-add-search").value.trim().toLowerCase();
    const inUse = new Set(dialogColumns.map((c) => c.value));
    const matches = (state.allFields || [])
      .filter((f) => !inUse.has(f.id) && (!query || f.name.toLowerCase().includes(query)))
      .slice(0, 20);
    const host = $("columns-add-results");
    host.innerHTML = "";
    for (const field of matches) {
      const option = document.createElement("div");
      option.className = "option";
      option.textContent = field.name;
      option.onclick = () => {
        dialogColumns.push({ label: field.name, value: field.id });
        renderColumnsCurrent();
        onColumnsSearchInput();
      };
      host.appendChild(option);
    }
  }, 150);
}

async function saveColumns() {
  try {
    const result = await api(`/api/filter/${encodeURIComponent(state.filter.id)}/columns`, {
      method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ fieldIds: dialogColumns.map((c) => c.value) }),
    });
    applyColumnsResult(result);
  } catch (error) {
    $("columns-error").textContent = error.message;
  }
}

async function resetColumns() {
  try {
    const result = await api(`/api/filter/${encodeURIComponent(state.filter.id)}/columns`, {
      method: "DELETE",
    });
    applyColumnsResult(result);
  } catch (error) {
    $("columns-error").textContent = error.message;
  }
}

function applyColumnsResult(result) {
  state.columns = result.columns;
  state.columnsAreDefault = result.isDefault;
  $("dlg-columns").close();
  populateSortAndGroupOptions();
  renderContent();
}

function showIssue(issue) {
  $("issue-pane-placeholder").style.display = "none";
  $("issue-pane-bar").style.display = "flex";
  $("issue-pane-key").textContent = issue.key;
  $("issue-pane-open").href = issue.browseUrl;
  // The real Jira page, fully interactive (spec §3.2). Jira instances that forbid framing
  // (X-Frame-Options) render blank — the "Open in Jira" link stays as the guaranteed path.
  const frame = $("issue-frame");
  frame.style.display = "";
  frame.src = issue.browseUrl;
}

/* ---------- Query editor (spec §3.3, §3.3.1) ---------- */
//
// The editor is a live `contenteditable` surface, not a plain textarea behind a highlight
// overlay. A `filter = <id>` clause renders as a real inline chip element — atomic,
// clickable, sitting in the text flow exactly where the clause is — by nesting a
// `contenteditable="false"` span inside the `contenteditable="true"` container. Browsers
// treat such a span as a single caret-stop and a single unit for selection and deletion,
// which is the same mechanism every "@mention pill" editor relies on; nothing exotic is
// needed beyond that.
//
// The editor's own DOM *is* the source of truth for text — there is no separately tracked
// string. Editing works by: extracting the plain JQL from the DOM (`canonicalText`),
// deriving the caret's position as a character offset into that string (`caretOffsetInRoot`),
// rebuilding the highlighted/chipped HTML from the string, and placing the caret back at the
// same offset (`setCaretOffset`). A match only turns into a chip once the caret is not
// touching it — otherwise typing the id's digits would snap into a pill mid-keystroke.

const JQL_KEYWORDS = /\b(AND|OR|NOT|IN|IS|WAS|CHANGED|EMPTY|NULL|ORDER BY|ASC|DESC|ON|BY|DURING|BEFORE|AFTER|FROM|TO)\b/gi;
const JQL_FUNCTIONS = /\b(currentUser|membersOf|now|startOfDay|endOfDay|startOfWeek|endOfWeek|startOfMonth|endOfMonth|linkedIssues|issueHistory|openSprints|closedSprints)\s*\(/gi;
const FILTER_REF = /\bfilter\s*=\s*(\d+)/gi;
const filterNamesById = {};
const pendingNameLookups = new Set();
let commitDebounceTimer = null;

/// Removes a trailing `ORDER BY ...` clause, so the active toolbar sort can replace it rather
/// than pile up behind it.
function stripOrderBy(jql) {
  return jql.replace(/\s*\border\s+by\s+.+$/i, "").trim();
}

function openQueryPanel() {
  // The toolbar's active sort is folded into what the editor shows, so "sort, then open Edit
  // Query, then Apply" persists it in one step — without this, Apply would silently discard
  // whatever sort was showing and save the filter's original order instead.
  let jql = state.filter.jql || "";
  if (state.sortField) {
    const base = stripOrderBy(jql);
    // A base that's already multiline (the filter was saved with manual line breaks —
    // `maybeAutoFormatJQL` never touches those) gets a newline ahead of `ORDER BY`, not glued
    // onto the last condition's line with a bare space — that would read as one long run-on
    // line no reformatting pass ever fixes, since the result already "has newlines" and so
    // looks manually formatted from then on.
    const separator = base.includes("\n") ? "\n" : " ";
    jql = `${base}${base ? separator : ""}ORDER BY ${state.sortField} ${state.sortDir.toUpperCase()}`;
  }
  setEditorText(jql, null);
  $("query-errors").textContent = "";
  $("query-panel").classList.add("open");
  $("jql-editor").focus();
  // The panel is positioned (not display:none), so the editor already has a real width to
  // measure here even before .open's slide-down transition finishes.
  maybeAutoFormatJQL();
}

function highlightPlain(segment) {
  let html = escapeHTML(segment);
  html = html.replace(/(&quot;.*?&quot;|'[^']*')/g, `<span class="str">$1</span>`);
  html = html.replace(JQL_FUNCTIONS, (m) => `<span class="fn">${m}</span>`);
  html = html.replace(JQL_KEYWORDS, (m) => `<span class="kw">${m}</span>`);
  html = html.replace(/\b(\d+[dwhm]?)\b/g, `<span class="num">$1</span>`);
  return html;
}

function chipHTML(id) {
  const name = filterNamesById[id] || `#${id}`;
  return `<span class="filter-chip" contenteditable="false" tabindex="-1" data-id="${id}" title="Click to change the reference · ⌘/Ctrl-click to open ${escapeHTML(name)}">🔗 ${escapeHTML(name)} <span class="caret">▾</span></span>`;
}

/// Builds the editor's inner HTML from plain JQL text.
///
/// `caretOffset` — `null` means "no caret in the editor right now" (blur, or a fresh
/// programmatic set): every match commits to a chip. Otherwise a match straddling the caret
/// (inclusive of its boundaries) stays as plain highlighted text, so an id mid-typing is
/// never yanked into a pill out from under the user.
function buildEditorHTML(text, caretOffset) {
  let html = "";
  let lastIndex = 0;
  let match;
  FILTER_REF.lastIndex = 0;
  while ((match = FILTER_REF.exec(text))) {
    const start = match.index;
    const end = start + match[0].length;
    const id = match[1];
    html += highlightPlain(text.slice(lastIndex, start));
    if (caretOffset !== null && caretOffset >= start && caretOffset <= end) {
      html += highlightPlain(match[0]);
    } else {
      resolveFilterName(id);
      html += chipHTML(id);
    }
    lastIndex = end;
  }
  html += highlightPlain(text.slice(lastIndex));
  return html;
}

/* ----- Canonical text ⇄ DOM, and caret offset ⇄ DOM position ----- */

function nodeCanonicalLength(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent.length;
  if (node.classList?.contains("filter-chip")) return `filter = ${node.dataset.id}`.length;
  let total = 0;
  for (const child of node.childNodes) total += nodeCanonicalLength(child);
  return total;
}

function canonicalText(root) {
  let text = "";
  for (const node of root.childNodes) {
    if (node.nodeType === Node.TEXT_NODE) text += node.textContent;
    else if (node.classList?.contains("filter-chip")) text += `filter = ${node.dataset.id}`;
    else text += canonicalText(node);
  }
  return text;
}

function caretOffsetInRoot(root) {
  const selection = window.getSelection();
  if (!selection.rangeCount) return null;
  const range = selection.getRangeAt(0);
  if (!root.contains(range.startContainer)) return null;
  return offsetOfPosition(root, range.startContainer, range.startOffset);
}

/// Converts a DOM (node, offset) position — as `Range`/`Selection` express it — into a
/// character offset in the string `canonicalText` would produce.
function offsetOfPosition(root, targetNode, targetOffset) {
  let total = 0;
  let found = null;
  (function walk(node) {
    if (found !== null) return;
    if (node === targetNode) {
      if (node.nodeType === Node.TEXT_NODE) {
        found = total + targetOffset;
      } else {
        // The caret sits between child nodes of an element (e.g. right after a chip);
        // `targetOffset` is a child index here, not a character count.
        let sum = total;
        for (let i = 0; i < targetOffset; i++) sum += nodeCanonicalLength(node.childNodes[i]);
        found = sum;
      }
      return;
    }
    if (node.nodeType === Node.TEXT_NODE) {
      total += node.textContent.length;
      return;
    }
    if (node.classList?.contains("filter-chip")) {
      total += `filter = ${node.dataset.id}`.length;
      return;
    }
    for (const child of node.childNodes) {
      walk(child);
      if (found !== null) return;
    }
  })(root);
  return found !== null ? found : total;
}

/// The current selection's bounds, as canonical-text offsets into `editor` — or `null` when
/// there's no selection, or it isn't entirely inside `editor` (a copy/cut spanning outside it,
/// e.g. into the sidebar, is left to the browser's own handling rather than second-guessed
/// here). Used by the `copy`/`cut` handlers below in place of the browser's own plain-text
/// serialization of the selection, which silently drops a chip's content entirely — Chrome
/// treats a `contenteditable="false"` island nested inside an editable host as empty rather
/// than including its text when producing `text/plain`, so copying a query containing a
/// `filter = <id>` reference would otherwise lose that whole condition.
function selectedCanonicalRange(editor) {
  const selection = window.getSelection();
  if (!selection.rangeCount) return null;
  const range = selection.getRangeAt(0);
  if (!editor.contains(range.startContainer) || !editor.contains(range.endContainer)) return null;
  const a = offsetOfPosition(editor, range.startContainer, range.startOffset);
  const b = offsetOfPosition(editor, range.endContainer, range.endOffset);
  return { start: Math.min(a, b), end: Math.max(a, b) };
}

/// The inverse of `offsetOfPosition`: places the DOM caret at a canonical character offset.
function setCaretOffset(root, offset) {
  let remaining = offset;
  let result = null;
  (function walk(node) {
    if (result) return;
    for (const child of Array.from(node.childNodes)) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (remaining <= child.textContent.length) {
          result = { node: child, offset: Math.max(0, remaining) };
          return;
        }
        remaining -= child.textContent.length;
      } else if (child.classList?.contains("filter-chip")) {
        const len = `filter = ${child.dataset.id}`.length;
        if (remaining <= len) {
          // Caret cannot land "inside" an atomic chip — land just before or after it.
          const index = Array.prototype.indexOf.call(node.childNodes, child);
          result = { node, offset: index + (remaining > 0 ? 1 : 0) };
          return;
        }
        remaining -= len;
      } else {
        walk(child);
      }
      if (result) return;
    }
  })(root);
  if (!result) {
    result = { node: root, offset: root.childNodes.length };
  }
  const range = document.createRange();
  range.setStart(result.node, result.offset);
  range.collapse(true);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

/* ----- Rendering ----- */

function renderEditor(explicitCaretOffset) {
  const editor = $("jql-editor");
  const text = canonicalText(editor);
  const caretOffset = explicitCaretOffset !== undefined ? explicitCaretOffset : caretOffsetInRoot(editor);
  editor.innerHTML = buildEditorHTML(text, caretOffset);
  if (caretOffset !== null) setCaretOffset(editor, caretOffset);
}

function setEditorText(text, caretOffset) {
  const editor = $("jql-editor");
  editor.innerHTML = buildEditorHTML(text, caretOffset);
  if (caretOffset !== null) setCaretOffset(editor, caretOffset);
}

function insertPlainTextAtCaret(text) {
  const editor = $("jql-editor");
  const current = canonicalText(editor);
  const offset = caretOffsetInRoot(editor) ?? current.length;
  const newText = current.slice(0, offset) + text + current.slice(offset);
  setEditorText(newText, offset + text.length);
}

/* ----- Resolving referenced filters' names ----- */

async function resolveFilterName(id) {
  if (filterNamesById[id] || pendingNameLookups.has(id)) return;
  pendingNameLookups.add(id);
  try {
    const detail = await api(`/api/filter/${encodeURIComponent(id)}`);
    filterNamesById[id] = detail.filter.name;
  } catch {
    filterNamesById[id] = `#${id} (not found)`;
  } finally {
    pendingNameLookups.delete(id);
    renderEditor(); // picks up the live caret if the editor is focused, else null
  }
}

/* ----- The "change which filter" picker ----- */

let chipPickerTarget = null; // { id } of the reference currently being reassigned

function openChipPicker(chip, id, event) {
  event.stopPropagation();
  chipPickerTarget = { id };
  const popover = $("chip-popover");
  const rect = chip.getBoundingClientRect();
  popover.style.left = `${rect.left}px`;
  popover.style.top = `${rect.bottom + 4}px`;
  popover.style.display = "block";
  $("chip-search").value = "";
  $("chip-options").innerHTML = `<div class="empty">Type to search…</div>`;
  $("chip-search").focus();
}

function closeChipPicker() {
  $("chip-popover").style.display = "none";
  chipPickerTarget = null;
}

let chipSearchTimer = null;
function onChipSearchInput() {
  clearTimeout(chipSearchTimer);
  const query = $("chip-search").value.trim();
  chipSearchTimer = setTimeout(async () => {
    if (!query) { $("chip-options").innerHTML = `<div class="empty">Type to search…</div>`; return; }
    try {
      const results = await api(`/api/filters/search?q=${encodeURIComponent(query)}`);
      renderChipOptions(results);
    } catch (error) {
      $("chip-options").innerHTML = `<div class="empty">${escapeHTML(error.message)}</div>`;
    }
  }, 200);
}

function renderChipOptions(results) {
  const host = $("chip-options");
  if (!results.length) { host.innerHTML = `<div class="empty">No matches.</div>`; return; }
  host.innerHTML = "";
  for (const filter of results) {
    const option = document.createElement("div");
    option.className = "option";
    option.textContent = filter.name;
    option.onclick = () => applyChipSelection(filter);
    host.appendChild(option);
  }
}

function applyChipSelection(filter) {
  if (!chipPickerTarget) return;
  filterNamesById[filter.id] = filter.name;
  const oldId = chipPickerTarget.id;
  const pattern = new RegExp(`(\\bfilter\\s*=\\s*)${oldId}\\b`, "gi");
  const newText = canonicalText($("jql-editor")).replace(pattern, `$1${filter.id}`);
  closeChipPicker();
  setEditorText(newText, null);
}

/* ----- Dragging a filter from the sidebar into the editor ----- */

function setupChipDropTarget() {
  const editor = $("jql-editor");
  editor.ondragover = (event) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    editor.classList.add("drop-target");
  };
  editor.ondragleave = () => editor.classList.remove("drop-target");
  editor.ondrop = (event) => {
    event.preventDefault();
    editor.classList.remove("drop-target");
    const raw = event.dataTransfer.getData("application/x-swira-filter");
    if (!raw) return;
    const filter = JSON.parse(raw);
    filterNamesById[filter.id] = filter.name;
    insertFilterReference(filter.id, editorOffsetAtPoint(editor, event.clientX, event.clientY));
  };
}

/// The canonical text offset under a screen point, or `null` when the browser can't resolve one
/// (no `caretRangeFromPoint`/`caretPositionFromPoint` support) or it lands outside the editor —
/// callers fall back to their own default in that case.
function editorOffsetAtPoint(editor, x, y) {
  let node, offset;
  if (document.caretRangeFromPoint) {
    const range = document.caretRangeFromPoint(x, y);
    if (!range) return null;
    node = range.startContainer;
    offset = range.startOffset;
  } else if (document.caretPositionFromPoint) {
    const position = document.caretPositionFromPoint(x, y);
    if (!position) return null;
    node = position.offsetNode;
    offset = position.offset;
  } else {
    return null;
  }
  if (!editor.contains(node)) return null;

  // caretRangeFromPoint/caretPositionFromPoint hit-test the literal nearest text position and,
  // unlike a real click, don't respect contenteditable="false" — a drop landing visually over a
  // chip can resolve to a position *inside* its rendered label ("🔗 Swira: Gen1 ▾"). A chip is
  // atomic everywhere else in this file (see setCaretOffset's own "cannot land inside" handling
  // just below), and offsetOfPosition only knows how to place a caret next to one as a whole —
  // handed a node from inside its label instead, it sums that label's own rendered text length
  // rather than the chip's five-or-so-character canonical `filter = <id>`, landing the drop at a
  // bogus offset that then splices the new condition into the middle of the existing one's
  // characters, breaking it. Snap to just before or after the chip first, by whichever half of
  // it the point falls in.
  const chip = node.nodeType === Node.ELEMENT_NODE && node.classList?.contains("filter-chip")
    ? node
    : node.parentElement?.closest(".filter-chip");
  if (chip) {
    const rect = chip.getBoundingClientRect();
    const before = x < rect.left + rect.width / 2;
    const index = Array.prototype.indexOf.call(chip.parentNode.childNodes, chip);
    return offsetOfPosition(editor, chip.parentNode, before ? index : index + 1);
  }

  return offsetOfPosition(editor, node, offset);
}

/// Splits `jql` into the conditions and a trailing `ORDER BY ...`, if any — the new condition
/// belongs before that clause, never after it.
function splitOrderBy(jql) {
  const match = jql.match(/\s*(\border\s+by\s+.+)$/i);
  return match
    ? { base: jql.slice(0, match.index).trim(), orderBy: match[1].trim() }
    : { base: jql.trim(), orderBy: "" };
}

/// The `AND`/`OR` keywords joining `jql`'s top-level conditions — parenthesized groups don't
/// count, since a connective inside one joins that group's own sub-conditions, not the outer
/// ones a dropped filter is about to join.
function topLevelConnectives(jql) {
  const found = [];
  let depth = 0;
  const re = /\(|\)|\b(AND|OR)\b/gi;
  let match;
  while ((match = re.exec(jql))) {
    if (match[0] === "(") depth++;
    else if (match[0] === ")") depth--;
    else if (depth === 0) found.push(match[1].toUpperCase());
  }
  return found;
}

/// The innermost parenthesized group `at` sits inside, as a `[start, end)` span of `base` — the
/// whole of `base` when `at` isn't inside any parens. Used to scope connective-agreement
/// (`topLevelConnectives`) to the group being inserted into, not the outermost query — a drop
/// inside `(priority = High OR priority = Critical)` must join with `OR`, regardless of what
/// connective the rest of the query outside that group happens to use.
function enclosingGroupBounds(base, at) {
  const opens = [];
  for (let i = 0; i < at; i++) {
    if (base[i] === "(") opens.push(i);
    else if (base[i] === ")") opens.pop();
  }
  if (!opens.length) return { start: 0, end: base.length };
  const openIndex = opens[opens.length - 1];
  let depth = 1;
  let end = base.length;
  for (let i = openIndex + 1; i < base.length; i++) {
    if (base[i] === "(") depth++;
    else if (base[i] === ")") { depth--; if (depth === 0) { end = i; break; } }
  }
  return { start: openIndex + 1, end };
}

/// True when nothing meaningful separates `at` from the nearest thing before it that already
/// expects a fresh condition to follow — the very start of the query, an opening paren, or a
/// dangling `AND`/`OR`/`NOT`. No connective belongs in front of the inserted condition when
/// this holds: one immediately before it is already doing that job.
function isBareBefore(base, at) {
  let i = at;
  while (i > 0 && /\s/.test(base[i - 1])) i--;
  if (i === 0 || base[i - 1] === "(") return true;
  return /\b(AND|OR|NOT)$/i.test(base.slice(0, i));
}

/// The mirror of `isBareBefore`, looking forward instead: true when nothing meaningful
/// separates `at` from whatever already expects to follow a fresh condition — the very end of
/// the query, a closing paren, or a connective the user already typed right after the drop
/// point. No connective belongs *after* the inserted condition when this holds, for the same
/// reason `isBareBefore` withholds one in front. Without this check, a drop landing right in
/// front of an existing bare condition (e.g. one `isBareBefore` itself just inserted nothing in
/// front of) would leave two conditions sitting side by side with nothing joining them — not
/// merely a style nit, but invalid JQL.
function isBareAfter(base, at) {
  let i = at;
  while (i < base.length && /\s/.test(base[i])) i++;
  if (i === base.length || base[i] === ")") return true;
  return /^(AND|OR|NOT)\b/i.test(base.slice(i));
}

/// Inserts a `filter = <id>` condition into the query, either at a specific canonical-text
/// `offset` — a drag-and-drop landing point, resolved by `editorOffsetAtPoint` — or, when
/// `offset` is `null`/unresolved, appended as a new top-level condition at the end. Either way
/// the insertion point is clamped to land before a trailing `ORDER BY`, so a dropped reference
/// never ends up split across the sort clause.
///
/// Any connective needed either side of the condition is decided the way the existing
/// conditions *at that insertion point* already agree with each other — `OR` if the enclosing
/// group (§`enclosingGroupBounds`) already joins with `OR`, `AND` otherwise — never a blind
/// `AND` that would silently change an `OR`-based query's or group's meaning. Whichever side
/// (`isBareBefore`/`isBareAfter`) already has one right there — the start/end of the query, a
/// paren, or a connective the user already typed — gets no connective added on top of it; the
/// other side gets one, so the inserted condition never ends up sitting next to its neighbour
/// with nothing joining them.
///
/// This is a heuristic over the plain text, like the rest of this editor's JQL handling (see the
/// autocomplete comment above `detectCompletionContext`) — it reasons about the drop point's
/// immediate surroundings, not full JQL precedence, so a drop wedged mid-clause in unusual spots
/// (e.g. between a dangling `NOT` and the parenthesized group it negates) isn't guaranteed to
/// come out perfectly. The common drop points — end of the query, an empty group, right after a
/// connective the user just typed, right in front of an existing condition — are exactly the
/// ones it gets right.
function insertFilterReference(id, offset) {
  const editor = $("jql-editor");
  const text = canonicalText(editor);
  const condition = `filter = ${id}`;

  const orderByMatch = text.match(/\s*(\border\s+by\s+.+)$/i);
  const baseEnd = orderByMatch ? orderByMatch.index : text.length;
  const base = text.slice(0, baseEnd);
  const at = offset == null ? baseEnd : Math.max(0, Math.min(offset, baseEnd));

  const bareBefore = isBareBefore(base, at);
  const bareAfter = isBareAfter(base, at);
  let prefix = "";
  let suffix = "";
  if (!bareBefore || !bareAfter) {
    const { start, end } = enclosingGroupBounds(base, at);
    const connective = topLevelConnectives(base.slice(start, end)).includes("OR") ? "OR" : "AND";
    if (!bareBefore) prefix = `${connective} `;
    if (!bareAfter) suffix = ` ${connective}`;
  }
  const piece = `${prefix}${condition}${suffix}`;

  const before = text.slice(0, at);
  const after = text.slice(at);
  // Exactly one separating space where one's needed, without doubling one that's already
  // there, and without one at all right against an opening/closing paren.
  const sep1 = before && !/[\s(]$/.test(before) ? " " : "";
  const sep2 = after && !/^[\s)]/.test(after) ? " " : "";
  let newText = `${before}${sep1}${piece}${sep2}${after}`;

  // The caret must land strictly past the inserted `filter = <id>` clause's own match boundary
  // — buildEditorHTML treats a caret still touching a match as "being typed" and leaves it as
  // plain text rather than committing it to a chip (the same rule that keeps an id being typed
  // from snapping into a pill mid-keystroke). A trailing connective (`suffix`) already provides
  // that room. Otherwise, landing one character further — into whatever already follows (a
  // separating space, or straight into a `)` with none) — clears the boundary without adding
  // anything to the text. Only when there's truly nothing at all after the drop point (the very
  // end of the query) does a space need inserting, purely to give the caret somewhere to go.
  const matchEnd = before.length + sep1.length + prefix.length + condition.length;
  let caret;
  if (suffix) {
    caret = matchEnd + suffix.length;
  } else if (after === "") {
    newText += " ";
    caret = newText.length;
  } else {
    caret = matchEnd + 1;
  }

  editor.focus();
  setEditorText(newText, caret);
}

/* ----- Multiline JQL formatting ----- */
//
// A query that wouldn't fit the editor's width as one line is reformatted into an indented
// multiline layout instead of just soft-wrapping mid-token — breaking at top-level AND/OR onto
// their own lines and recursing into parenthesized groups only as deep as actually needed, so a
// nested clause that already fits stays inline even inside one that doesn't. This never touches
// a query the user has already broken into lines themselves; auto-formatting only ever turns a
// too-wide single line into multiple, never reflows existing manual line breaks.

const JQL_INDENT_UNIT = 2;
// A short list of conditions (or IN-values) reads fine on one line even once the query around
// it has gone multiline — e.g. `(priority = High OR priority = Critical)` — so it's kept inline
// whenever it fits, same as any other clause. Once a group holds more pieces than this, though,
// it's forced onto its own multiple lines even if it would technically still fit the width: a
// five-way OR crammed onto one line is harder to scan than one that's merely a little wide, the
// same tradeoff most SQL formatters make for long clause lists and IN-lists alike.
const JQL_INLINE_LIMIT = 3;

/// The pixel width of one monospace character in the editor's font, measured once via canvas
/// and cached — the editor's own font is set in CSS (`#jql-wrap`), so this must track it.
let cachedJQLCharWidth = null;
function jqlCharWidth() {
  if (cachedJQLCharWidth) return cachedJQLCharWidth;
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d");
  context.font = "13px ui-monospace, Consolas, monospace";
  cachedJQLCharWidth = context.measureText("M").width || 7.8;
  return cachedJQLCharWidth;
}

/// How many characters currently fit across the editor's own width — the "print width" the
/// formatter wraps to. Recomputed on demand rather than cached, since the panel/window can be
/// resized between edits.
function jqlColumnBudget() {
  const editor = $("jql-editor");
  const style = getComputedStyle(editor);
  const available = editor.clientWidth - parseFloat(style.paddingLeft || "0") - parseFloat(style.paddingRight || "0");
  return Math.max(20, Math.floor(available / jqlCharWidth()));
}

/// Splits `expr` into pieces joined by top-level `AND`/`OR` — mirrors `topLevelConnectives`'s
/// paren-depth tracking, but returns the actual substrings too, which is what the formatter
/// below needs to lay each one out on its own line.
function splitTopLevelJQL(expr) {
  const parts = [];
  const connectives = [];
  let depth = 0;
  let start = 0;
  let i = 0;
  while (i < expr.length) {
    const ch = expr[i];
    if (ch === "(") { depth++; i++; continue; }
    if (ch === ")") { depth--; i++; continue; }
    if (depth === 0) {
      const match = /^(AND|OR)\b/i.exec(expr.slice(i));
      if (match && /\s/.test(expr[i - 1] || " ")) {
        parts.push(expr.slice(start, i).trim());
        connectives.push(match[1].toUpperCase());
        i += match[0].length;
        start = i;
        continue;
      }
    }
    i++;
  }
  parts.push(expr.slice(start).trim());
  return { parts, connectives };
}

/// True when `text` is one parenthesized group spanning it entirely — not merely a leaf
/// condition that happens to contain parens, like `status in (Open, "In Progress")`.
function isParenWrapped(text) {
  if (!text.startsWith("(") || !text.endsWith(")")) return false;
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "(") depth++;
    else if (text[i] === ")") {
      depth--;
      if (depth === 0) return i === text.length - 1;
    }
  }
  return false;
}

/// The `(head, inner)` split of `text`'s *trailing* parenthesized group — the `(...)` that ends
/// the string, however much comes before it — or `null` if `text` doesn't end with one. Unlike
/// `isParenWrapped`, `head` doesn't have to be empty: this is what finds the value list on a
/// leaf condition like `priority in (High, Highest)`, where the group is only part of the
/// clause, not the whole of it.
function trailingParenGroup(text) {
  if (!text.endsWith(")")) return null;
  let depth = 0;
  for (let i = text.length - 1; i >= 0; i--) {
    if (text[i] === ")") depth++;
    else if (text[i] === "(") {
      depth--;
      if (depth === 0) return { head: text.slice(0, i), inner: text.slice(i + 1, -1) };
    }
  }
  return null;
}

/// Splits a comma-separated list on its top-level commas — parens and quoted strings are
/// opaque, mirroring `splitTopLevelJQL`'s treatment of `AND`/`OR`. Used for an `IN (...)`
/// clause's value list, so `field in ("a, b", c)` doesn't split inside the quoted value.
function splitTopLevelCommaList(text) {
  const parts = [];
  let depth = 0;
  let quote = null;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote) {
      if (ch === "\\") { i++; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    else if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === "," && depth === 0) {
      parts.push(text.slice(start, i).trim());
      start = i + 1;
    }
  }
  parts.push(text.slice(start).trim());
  return parts;
}

/// True when `text`, laid out as one line however wide, would still read as too dense to be
/// worth it — some clause list *anywhere* in it (top-level, inside a parenthesized group, or an
/// `IN`-list's values), not just at `text`'s own top level, holds more than `JQL_INLINE_LIMIT`
/// items. `formatJQLExpression`'s inline/exploded decision for a list needs this, not just its
/// own item count: a query with only 3 top-level conditions still needs to explode if one of
/// those 3 is itself a 5-way `OR` group, even though the flat text of all 3 together might
/// easily fit `columns` and 3 doesn't exceed the limit on its own.
function hasOversizedList(text) {
  const trimmed = text.trim();
  if (isParenWrapped(trimmed)) {
    const inner = trimmed.slice(1, -1).trim();
    if (!inner) return false;
    const { parts } = splitTopLevelJQL(inner);
    return parts.length > JQL_INLINE_LIMIT || parts.some(hasOversizedList);
  }
  const { parts } = splitTopLevelJQL(trimmed);
  if (parts.length > 1) {
    return parts.length > JQL_INLINE_LIMIT || parts.some(hasOversizedList);
  }
  const group = trailingParenGroup(trimmed);
  if (group && /\b(?:not\s+)?in\s*$/i.test(group.head)) {
    return splitTopLevelCommaList(group.inner).length > JQL_INLINE_LIMIT;
  }
  return false;
}

/// Lays out an `IN (...)`/`NOT IN (...)` clause's value list as `head(...)`: inline if it holds
/// at most `JQL_INLINE_LIMIT` values and fits `columns`, otherwise one value per line indented
/// under `head`'s own line, comma-terminated the way a long `IN`-list reads in most SQL
/// formatters.
function formatParenList(head, values, indent, columns) {
  if (!values.length) return `${head}()`;
  const oneLine = `${head}(${values.join(", ")})`;
  if (values.length <= JQL_INLINE_LIMIT && indent + oneLine.length <= columns) return oneLine;
  const innerIndent = indent + JQL_INDENT_UNIT;
  const body = values.join(`,\n${" ".repeat(innerIndent)}`);
  return `${head}(\n${" ".repeat(innerIndent)}${body}\n${" ".repeat(indent)})`;
}

/// Pretty-prints one JQL expression (no `ORDER BY`) to fit within `columns`, breaking at
/// top-level `AND`/`OR` onto their own lines indented by `indent` and recursing into
/// parenthesized groups and `IN`-lists only as deep as actually needed — a clause that already
/// fits, and isn't too long a list to read comfortably inline (`JQL_INLINE_LIMIT`), stays inline
/// even nested inside one that doesn't. `NOT`/`IN` are never treated as connectives to break on
/// (`splitTopLevelJQL` only splits `AND`/`OR`), so they always stay on the same line as the
/// condition they belong to.
function formatJQLExpression(text, indent, columns) {
  const trimmed = text.trim();

  if (isParenWrapped(trimmed)) {
    const inner = trimmed.slice(1, -1).trim();
    if (!inner) return "()";
    const { parts } = splitTopLevelJQL(inner);
    const oneLine = `(${inner})`;
    const fitsInline = parts.length <= JQL_INLINE_LIMIT && indent + oneLine.length <= columns
      && !parts.some(hasOversizedList);
    if (fitsInline) return oneLine;
    const innerIndent = indent + JQL_INDENT_UNIT;
    const formattedInner = formatJQLExpression(inner, innerIndent, columns);
    return `(\n${" ".repeat(innerIndent)}${formattedInner}\n${" ".repeat(indent)})`;
  }

  const { parts, connectives } = splitTopLevelJQL(trimmed);
  if (parts.length > 1) {
    const oneLine = parts.map((part, i) => (i === 0 ? part : `${connectives[i - 1]} ${part}`)).join(" ");
    const fitsInline = parts.length <= JQL_INLINE_LIMIT && indent + oneLine.length <= columns
      && !parts.some(hasOversizedList);
    if (fitsInline) return oneLine;
    return parts
      .map((part, i) => {
        const piece = formatJQLExpression(part, indent, columns);
        return i === 0 ? piece : `${connectives[i - 1]} ${piece}`;
      })
      .join(`\n${" ".repeat(indent)}`);
  }

  // A leaf condition — the last thing left to check is whether it's an `IN (...)`/`NOT IN
  // (...)` clause with a value list long enough to lay out one value per line, e.g.
  // `priority in (High, Highest, Critical, Blocker)`. Anything else (a plain comparison, a
  // function call, a value list itself already short) is returned as-is: it's a single unit
  // that stays on one line no matter what surrounds it.
  const group = trailingParenGroup(trimmed);
  if (group && /\b(?:not\s+)?in\s*$/i.test(group.head)) {
    const values = splitTopLevelCommaList(group.inner);
    if (values.length) return formatParenList(group.head, values, indent, columns);
  }
  return trimmed;
}

/// Reformats `jql` as indented multiline if, laid out flat as one line, it wouldn't fit
/// `columns` characters *or* some clause list is long enough that `formatJQLExpression` breaks
/// it up on its own account (`JQL_INLINE_LIMIT`) — otherwise collapses it back to one flat line
/// unchanged. `formatJQLExpression` always runs, rather than only once a width check fails, so
/// that second trigger applies even to a query that would otherwise fit comfortably. A trailing
/// `ORDER BY` always lands on its own line once anything else goes multiline, and is never
/// itself split.
function formatJQLIfNeeded(jql, columns) {
  const { base, orderBy } = splitOrderBy(jql);
  if (!base) return orderBy;
  const flatBase = base.replace(/\s+/g, " ").trim();
  const formattedBase = formatJQLExpression(flatBase, 0, columns);
  const combinedFits = !formattedBase.includes("\n")
    && (orderBy ? formattedBase.length + 1 + orderBy.length : formattedBase.length) <= columns;
  if (combinedFits) return orderBy ? `${formattedBase} ${orderBy}` : formattedBase;
  return orderBy ? `${formattedBase}\n${orderBy}` : formattedBase;
}

/// Auto-formats the editor's current text into multiline once it no longer fits on one line.
/// Only acts on text that's still a single physical line — a query the user has already broken
/// into lines by hand is left exactly as they wrote it, never collapsed and reflowed against
/// their own formatting. Returns whether it changed anything, so callers that also want to
/// re-render on a no-op (e.g. to commit chips on blur) know whether this already did that.
function maybeAutoFormatJQL() {
  const editor = $("jql-editor");
  const text = canonicalText(editor);
  if (text.includes("\n")) return false;
  const formatted = formatJQLIfNeeded(text, jqlColumnBudget());
  if (formatted === text) return false;
  setEditorText(formatted, null);
  return true;
}

/* ----- Wiring: typing, Enter, paste, blur, clicking a chip ----- */

/* ---------- JQL autocomplete ---------- */
//
// Not a real JQL parser — a heuristic over the plain text: find the partial word at the
// caret, then classify it by what immediately precedes it. If that's a comparison operator
// (`=`, `!=`, `~`, `in (`, …) with no intervening clause boundary, we're completing a *value*
// for the field named just before the operator; otherwise we're completing a *field name*.
// This covers ordinary typing well without attempting to handle every nested-function or
// quoted-string edge case JQL's real grammar allows.

const JQL_CLAUSE_BOUNDARY = /\b(?:AND|OR)\b|\(/i;

function detectCompletionContext(text, caretOffset) {
  const before = text.slice(0, caretOffset);
  const wordMatch = before.match(/[A-Za-z0-9_.\[\]]*$/);
  const partial = wordMatch[0];
  const wordStart = caretOffset - partial.length;
  const beforeWord = before.slice(0, wordStart);

  // An `in`-list first: `field in (`, `field not in (Done, `, … The clause-boundary split
  // below treats `(` as a boundary (right for grouping parens), which is exactly what used to
  // erase this context — so it needs its own detection, keyed on the last *unclosed* paren.
  let depth = 0;
  let openIndex = -1;
  for (let i = beforeWord.length - 1; i >= 0; i--) {
    const ch = beforeWord[i];
    if (ch === ")") depth++;
    else if (ch === "(") {
      if (depth === 0) { openIndex = i; break; }
      depth--;
    }
  }
  if (openIndex >= 0) {
    const inMatch = beforeWord.slice(0, openIndex).match(/([A-Za-z0-9_.\[\]]+)\s+(?:not\s+)?in\s*$/i);
    // Suggest only at the start of a list item — right after `(` or after a comma. Elsewhere
    // inside the list (say, right after a completed item) the next meaningful token is a comma
    // or `)`, not a value.
    const atItemStart = /(?:^|,)\s*$/.test(beforeWord.slice(openIndex + 1));
    if (inMatch && atItemStart) {
      return { kind: "value", fieldName: inMatch[1], partial, wordStart };
    }
  }

  const segments = beforeWord.split(JQL_CLAUSE_BOUNDARY);
  const clause = segments[segments.length - 1];
  const operatorMatch = clause.match(
    /^\s*([A-Za-z0-9_.\[\]]+)\s*(?:=|!=|~|!~|>=|<=|>|<)\s*$/i
  );

  if (operatorMatch) {
    return { kind: "value", fieldName: operatorMatch[1], partial, wordStart };
  }
  return { kind: "field", partial, wordStart };
}

/// The caret's on-screen position, for anchoring the suggestion popover under it rather than
/// under the editor as a whole.
function getCaretScreenRect(editor) {
  const selection = window.getSelection();
  if (selection.rangeCount) {
    const range = selection.getRangeAt(0).cloneRange();
    range.collapse(true);
    const rects = range.getClientRects();
    if (rects.length) return rects[0];
  }
  return editor.getBoundingClientRect();
}

let autocompleteTimer = null;
let autocompleteOptions = [];
let autocompleteIndex = -1;
let autocompleteContext = null;

function scheduleAutocomplete() {
  clearTimeout(autocompleteTimer);
  autocompleteTimer = setTimeout(updateAutocomplete, 150);
}

async function updateAutocomplete() {
  const editor = $("jql-editor");
  const text = canonicalText(editor);
  const caret = caretOffsetInRoot(editor);
  if (caret === null) { closeAutocomplete(); return; }

  const context = detectCompletionContext(text, caret);
  // An empty field-name query at every keystroke would mean showing the entire field list the
  // instant the editor opens or a clause starts — reserve that for once the user has typed
  // something. Values are useful to show even for an empty partial (e.g. right after `=`),
  // since Jira's own suggestions endpoint returns a sensible default list for that case.
  if (context.kind === "field" && context.partial.length === 0) {
    closeAutocomplete();
    return;
  }
  autocompleteContext = context;

  let options = [];
  if (context.kind === "field") {
    if (!state.jqlAutocomplete) {
      try {
        state.jqlAutocomplete = await api("/api/jql/autocomplete");
      } catch {
        closeAutocomplete();
        return;
      }
    }
    const query = context.partial.toLowerCase();
    options = [...state.jqlAutocomplete.fields, ...state.jqlAutocomplete.functions]
      .filter((f) => f.value.toLowerCase().includes(query) || f.label.toLowerCase().includes(query))
      .slice(0, 12);
  } else {
    try {
      options = await api(
        `/api/jql/suggestions?fieldName=${encodeURIComponent(context.fieldName)}`
          + `&fieldValue=${encodeURIComponent(context.partial)}`
      );
    } catch {
      closeAutocomplete();
      return;
    }
  }

  if (!options.length) { closeAutocomplete(); return; }
  showAutocomplete(options);
}

function showAutocomplete(options) {
  autocompleteOptions = options;
  autocompleteIndex = 0;
  const picker = $("jql-autocomplete");
  picker.innerHTML = options
    .map((o, i) => `<div class="option${i === 0 ? " active" : ""}" data-index="${i}">${escapeHTML(o.label)}</div>`)
    .join("");
  Array.from(picker.children).forEach((el, i) => {
    // mousedown, not click: fires before the editor's blur, the same reason every other
    // picker in this file uses it.
    el.onmousedown = (event) => { event.preventDefault(); acceptAutocomplete(i); };
  });
  positionFloatingPicker(picker, { getBoundingClientRect: () => getCaretScreenRect($("jql-editor")) });
}

function closeAutocomplete() {
  $("jql-autocomplete").style.display = "none";
  autocompleteOptions = [];
  autocompleteIndex = -1;
  autocompleteContext = null;
}

function moveAutocompleteSelection(delta) {
  if (!autocompleteOptions.length) return;
  autocompleteIndex = (autocompleteIndex + delta + autocompleteOptions.length) % autocompleteOptions.length;
  const picker = $("jql-autocomplete");
  Array.from(picker.children).forEach((el, i) => el.classList.toggle("active", i === autocompleteIndex));
  picker.children[autocompleteIndex]?.scrollIntoView({ block: "nearest" });
}

function acceptAutocomplete(index) {
  const option = autocompleteOptions[index];
  if (!option || !autocompleteContext) return;
  const editor = $("jql-editor");
  const text = canonicalText(editor);
  const { wordStart, partial, kind } = autocompleteContext;
  const wordEnd = wordStart + partial.length;
  const before = text.slice(0, wordStart);
  const after = text.slice(wordEnd);
  // A value containing whitespace needs quoting to stay one token; a field name never does.
  // Jira's suggestion endpoint already returns such values pre-quoted (`"In Progress"`,
  // quotes included) — re-quoting those would produce `""In Progress""`.
  const alreadyQuoted = /^".*"$/.test(option.value);
  const insertion = kind === "value" && /\s/.test(option.value) && !alreadyQuoted
    ? `"${option.value}"`
    : option.value;
  const newText = `${before}${insertion} ${after}`; // trailing space: ready to keep typing
  closeAutocomplete();
  setEditorText(newText, (before + insertion + " ").length);
  editor.focus();
}

function setupEditorEvents() {
  const editor = $("jql-editor");
  editor.addEventListener("input", () => {
    renderEditor();
    clearTimeout(commitDebounceTimer);
    // Commits a match into a chip once the user has paused, even without moving the caret
    // away from it (e.g. they typed a full id and just stopped).
    commitDebounceTimer = setTimeout(() => renderEditor(), 600);
    scheduleAutocomplete();
  });
  editor.addEventListener("blur", () => {
    // maybeAutoFormatJQL already re-renders (via setEditorText) when it actually reformats;
    // only fall back to a plain re-render for the ordinary case where it left the text alone.
    if (!maybeAutoFormatJQL()) renderEditor(null);
    setTimeout(closeAutocomplete, 150); // after any option's mousedown has had its say
  });
  editor.addEventListener("keydown", (event) => {
    if (autocompleteOptions.length) {
      if (event.key === "ArrowDown") { event.preventDefault(); moveAutocompleteSelection(1); return; }
      if (event.key === "ArrowUp") { event.preventDefault(); moveAutocompleteSelection(-1); return; }
      if (event.key === "Tab" || (event.key === "Enter" && autocompleteIndex >= 0)) {
        event.preventDefault();
        acceptAutocomplete(autocompleteIndex);
        return;
      }
      if (event.key === "Escape") { event.preventDefault(); closeAutocomplete(); return; }
    }
    // Ctrl+Enter (Cmd+Enter on Mac) applies, Escape cancels — the editor's own keyboard
    // shortcuts, distinct from plain Enter (a literal newline, JQL routinely spans lines) and
    // from autocomplete's Escape (dismiss suggestions only, handled above and already returned).
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      saveQuery();
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      $("query-panel").classList.remove("open");
      return;
    }
    if (event.key === "Enter") {
      // The editor holds only text nodes, highlight spans, and chips — never <div>/<br> block
      // elements — so newlines are always literal "\n" characters, rendered via
      // `white-space: pre-wrap`. Left to the browser, Enter would insert a block element
      // instead and break that invariant.
      event.preventDefault();
      insertPlainTextAtCaret("\n");
    }
  });
  editor.addEventListener("paste", (event) => {
    event.preventDefault();
    const text = (event.clipboardData || window.clipboardData).getData("text/plain");
    insertPlainTextAtCaret(text);
    // A pasted one-liner that overflows is exactly the case worth reformatting immediately,
    // rather than making the user click away first to see it laid out sensibly.
    maybeAutoFormatJQL();
  });
  editor.addEventListener("copy", (event) => {
    const bounds = selectedCanonicalRange(editor);
    if (!bounds) return; // selection isn't (fully) inside the editor — let the browser handle it
    event.clipboardData.setData("text/plain", canonicalText(editor).slice(bounds.start, bounds.end));
    event.preventDefault();
  });
  editor.addEventListener("cut", (event) => {
    const bounds = selectedCanonicalRange(editor);
    if (!bounds) return;
    const full = canonicalText(editor);
    event.clipboardData.setData("text/plain", full.slice(bounds.start, bounds.end));
    event.preventDefault();
    editor.focus();
    setEditorText(full.slice(0, bounds.start) + full.slice(bounds.end), bounds.start);
  });
  editor.addEventListener("click", (event) => {
    // For a `contenteditable="false"` child nested in a `contenteditable="true"` host,
    // Chrome sometimes resolves `event.target` to the host itself rather than the chip under
    // the cursor — apparently a side effect of the browser also repositioning the caret as
    // part of the same click. Hit-testing the actual coordinates is the reliable fallback.
    const chip = event.target.closest(".filter-chip")
      ?? document.elementFromPoint(event.clientX, event.clientY)?.closest(".filter-chip");
    if (!chip) return;
    const id = chip.dataset.id;
    // Cmd-click (Mac) / Ctrl-click (Windows/Linux) navigates to the referenced filter itself —
    // the standard "follow this reference" gesture (open link in new tab, jump to definition),
    // not Shift (range selection) or Option/Alt (inconsistent across apps).
    if (event.metaKey || event.ctrlKey) {
      selectFilter({ id, name: filterNamesById[id] || `#${id}` });
      return;
    }
    openChipPicker(chip, id, event);
  });
}

async function saveQuery() {
  try {
    const jql = canonicalText($("jql-editor"));
    await api(`/api/filter/${encodeURIComponent(state.filter.id)}/jql`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jql }),
    });
    $("query-panel").classList.remove("open");
    loadIssues();
    loadSidebar();
  } catch (error) {
    $("query-errors").textContent = error.message;
  }
}

/* ---------- Creation and deletion ---------- */

async function createFilter() {
  $("new-error").textContent = "";
  const name = $("new-name").value.trim();
  const jql = $("new-jql").value.trim();
  if (!name) { $("new-error").textContent = "Path is required."; return; }
  try {
    const created = await api("/api/filters", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        path: name.split(": "),
        jql,
        description: $("new-desc").value.trim() || null,
      }),
    });
    $("dlg-new").close();
    await loadSidebar();
    selectFilter(created.filter);
    // A filter with no conditions yet is the one case worth a follow-up nudge — jump straight
    // into Edit Query rather than leaving the user to notice the empty query themselves and
    // open it by hand.
    if (!created.filter.jql) openQueryPanel();
  } catch (error) {
    $("new-error").textContent = error.message;
  }
}

async function deleteFilter() {
  if (!state.filter) return;
  if (!confirm(`Delete filter "${state.filter.name}"? This cannot be undone.`)) return;
  try {
    await api(`/api/filter/${encodeURIComponent(state.filter.id)}`, { method: "DELETE" });
    state.filter = null;
    $("filter-title").textContent = "Select a filter";
    $("btn-edit-jql").disabled = true;
    $("btn-delete").disabled = true;
    $("table-view").innerHTML = `<div class="placeholder">Choose a filter in the sidebar.</div>`;
    loadSidebar();
  } catch (error) {
    showBanner(error.message);
  }
}

/* ---------- Chrome ---------- */

function showBanner(message) {
  const banner = $("banner");
  banner.textContent = message;
  banner.style.display = "block";
}

function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

/// Positions a shared, page-level `.floating-picker` (see `#assignee-picker`'s HTML comment)
/// just below `anchor`, flipping above it if there isn't room below. `position: fixed`, so
/// this is unaffected by any scrollable ancestor the anchor happens to sit inside.
function positionFloatingPicker(picker, anchor) {
  const rect = anchor.getBoundingClientRect();
  const margin = 6;
  // Not always "block": `#version-picker` is CSS `display: flex` (its search box and Apply
  // button stay put while only the checklist between them scrolls) — writing "block" here as
  // an inline style would beat that rule and collapse the layout back to one long list.
  picker.style.display = picker.id === "version-picker" ? "flex" : "block";
  // The picker needs a size before its height can inform the below-vs-above choice.
  const pickerHeight = picker.getBoundingClientRect().height;
  let top = rect.bottom + 4;
  if (top + pickerHeight > window.innerHeight - margin) {
    top = rect.top - pickerHeight - 4;
  }
  picker.style.left = `${Math.max(margin, rect.left)}px`;
  picker.style.top = `${Math.max(margin, top)}px`;
}

function hideFloatingPicker(picker) {
  picker.style.display = "none";
  picker.innerHTML = "";
}

/// Opens a `<dialog>` right below the button that triggered it, instead of the browser's
/// default of centering it in the viewport regardless of where the user clicked.
function showDialogNear(dialog, anchor) {
  dialog.classList.add("anchored");
  dialog.showModal();
  // The dialog has no measurable size until after showModal() opens it.
  const anchorRect = anchor.getBoundingClientRect();
  const dialogRect = dialog.getBoundingClientRect();
  const margin = 8;

  let left = anchorRect.left;
  if (left + dialogRect.width > window.innerWidth - margin) {
    left = window.innerWidth - dialogRect.width - margin;
  }
  left = Math.max(margin, left);

  let top = anchorRect.bottom + 6;
  if (top + dialogRect.height > window.innerHeight - margin) {
    // Not enough room below the button — open above it instead.
    top = anchorRect.top - dialogRect.height - 6;
  }
  top = Math.max(margin, top);

  dialog.style.top = `${top}px`;
  dialog.style.left = `${left}px`;
}

/// The visible text an HTML snippet renders as — used to recover a cell's displayed value
/// from its saved `original` markup (e.g. `<span class="dot ..."></span>High`) without
/// re-parsing by hand.
function plainTextOf(html) {
  const scratch = document.createElement("div");
  scratch.innerHTML = html;
  return scratch.textContent.trim();
}

$("btn-table").onclick = () => { state.view = "table"; renderContent(); };
$("btn-split").onclick = () => { state.view = "split"; renderContent(); };
$("btn-edit-jql").onclick = openQueryPanel;
$("btn-jql-cancel").onclick = () => $("query-panel").classList.remove("open");
$("btn-jql-ok").onclick = saveQuery;
$("btn-delete").onclick = deleteFilter;
$("btn-new").onclick = () => {
  $("new-name").value = "Swira: ";
  $("new-jql").value = ""; $("new-desc").value = ""; $("new-error").textContent = "";
  showDialogNear($("dlg-new"), $("btn-new"));
};
$("new-cancel").onclick = () => $("dlg-new").close();
$("new-ok").onclick = createFilter;
// The dialog prefills the group prefix so a same-group filter is one keystroke away — but that
// means a single Backspace, meant to clear the field and start over, would instead chew through
// it one character at a time. One Backspace against the untouched prefill clears it outright.
$("new-name").onkeydown = (event) => {
  if (event.key === "Backspace" && $("new-name").value === "Swira: ") {
    event.preventDefault();
    $("new-name").value = "";
  }
};
// Enter submits, same as clicking Create — wired on the single-line fields only. The JQL
// textarea keeps Enter as a plain newline, since JQL routinely spans multiple lines.
const submitNewFilterOnEnter = (event) => {
  if (event.key === "Enter") { event.preventDefault(); createFilter(); }
};
$("new-name").addEventListener("keydown", submitNewFilterOnEnter);
$("new-desc").addEventListener("keydown", submitNewFilterOnEnter);
// Space opens Edit Query for the current filter — a quicker path than reaching for the
// toolbar button — but only when it can't mean something else: not while typing anywhere
// (an input/textarea/contenteditable, including the JQL editor itself), not while a focused
// button would otherwise treat Space as "activate me", and not while a dialog already owns
// keyboard input.
document.addEventListener("keydown", (event) => {
  if (event.key !== " ") return;
  const target = event.target;
  const isTyping = target.tagName === "INPUT" || target.tagName === "TEXTAREA"
    || target.tagName === "SELECT" || target.tagName === "BUTTON" || target.isContentEditable;
  if (isTyping) return;
  if (document.querySelector("dialog[open]")) return;
  if (!state.filter || $("query-panel").classList.contains("open")) return;
  event.preventDefault();
  openQueryPanel();
});
$("btn-refresh-sidebar").onclick = () => loadSidebar(true);
$("chip-search").oninput = onChipSearchInput;
$("sort-field").onchange = () => { state.sortField = $("sort-field").value; loadIssues(); };
$("btn-sort-dir").onclick = () => {
  state.sortDir = state.sortDir === "asc" ? "desc" : "asc";
  $("btn-sort-dir").textContent = state.sortDir === "asc" ? "↑" : "↓";
  loadIssues();
};
$("group-field").onchange = () => { state.groupField = $("group-field").value; renderContent(); };
$("btn-columns").onclick = openColumnsDialog;
$("columns-cancel").onclick = () => $("dlg-columns").close();
$("columns-save").onclick = saveColumns;
$("columns-reset").onclick = resetColumns;
$("columns-add-search").oninput = onColumnsSearchInput;
document.addEventListener("mousedown", (event) => {
  if (chipPickerTarget && !$("chip-popover").contains(event.target)
      && !event.target.classList.contains("filter-chip")) {
    closeChipPicker();
  }
});
setupChipDropTarget();
setupEditorEvents();

(async function start() {
  const config = await api("/api/config").catch(() => ({}));
  if (config.error) { showBanner(config.error); return; }
  loadSidebar();
})();
</script>
</body>
</html>
"""#
}

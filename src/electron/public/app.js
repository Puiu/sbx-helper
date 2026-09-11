// public/app.js — UI state, tree rendering, keyboard handling.
// One state object, re-render the affected pane on change. No framework.

import { buildCommand, formatCommand } from './shared/command.mjs';
import { findCoveringPath, resolvePrimary } from './shared/selection.mjs';
import {
  defaultAgentArgs,
  tokenizeArgs,
  buildRunExistingArgs,
  isValidNetworkResource,
  parseResourceList,
  formatPort,
  MAX_RESOURCES_PER_REQUEST,
} from './shared/sandbox-commands.mjs';

function readStoredToken() {
  try {
    return sessionStorage.getItem('sbxHelperToken') || '';
  } catch {
    return ''; // sessionStorage can throw (private browsing, disabled site data) — non-fatal
  }
}

const state = {
  // The URL wins on first load; sessionStorage is the fallback once init()
  // has scrubbed the token out of the address bar (see below) — otherwise a
  // page reload after that point would have no way to find the token again.
  token: new URLSearchParams(location.search).get('t') || readStoredToken(),
  config: null,
  tree: [], // flat, depth-first pre-order: { path, name, depth, isGitRepo, unreadable }
  indexed: null, // { byPath, childrenOf, parentOf }
  hasGitDescendant: null, // Map<path, bool>
  templates: [],

  filterText: '',
  gitOnly: false,
  expanded: new Set(), // paths whose children are shown (root is always expanded)
  cursor: 0,
  visibleRows: [],

  selection: new Map(), // path -> 'editable' | 'readonly'
  primary: null, // explicit override, or null for the resolved default
  template: '',
  name: '',
  clone: false,

  // -- sandboxes tab --
  activeTab: 'builder', // 'builder' | 'sandboxes'
  sandboxes: [], // [{ name, id, agent, status, workspaces, ports }]
  sandboxesLoaded: false,
  sandboxesError: null,
  selectedSandbox: null, // name, not the object — survives a refresh's new object identity
  sandboxArgsText: new Map(), // name -> current text in the args field (session-only draft)
  policyRules: [],
  policiesFor: null, // which sandbox name state.policyRules belongs to
  sandboxBusy: false,
};

// -- tree indexing ------------------------------------------------------

function indexTree(flatNodes) {
  const byPath = new Map();
  const childrenOf = new Map();
  const parentOf = new Map();
  const stack = [];
  for (const node of flatNodes) {
    byPath.set(node.path, node);
    while (stack.length && stack[stack.length - 1].depth >= node.depth) stack.pop();
    const parent = stack.length ? stack[stack.length - 1] : null;
    parentOf.set(node.path, parent ? parent.path : null);
    if (parent) {
      if (!childrenOf.has(parent.path)) childrenOf.set(parent.path, []);
      childrenOf.get(parent.path).push(node.path);
    }
    stack.push(node);
  }
  return { byPath, childrenOf, parentOf };
}

// Descendants appear later than their ancestor in pre-order, so walking the
// array backwards guarantees every child of a node is already resolved by
// the time we reach that node.
function computeHasGitDescendant(flatNodes, childrenOf) {
  const result = new Map();
  for (let i = flatNodes.length - 1; i >= 0; i--) {
    const node = flatNodes[i];
    const kids = childrenOf.get(node.path) || [];
    const anyKidHas = kids.some((k) => result.get(k));
    result.set(node.path, !!node.isGitRepo || anyKidHas);
  }
  return result;
}

function reindex() {
  state.indexed = indexTree(state.tree);
  state.hasGitDescendant = computeHasGitDescendant(state.tree, state.indexed.childrenOf);
}

function expandAncestors(absPath) {
  let p = state.indexed.parentOf.get(absPath);
  while (p) {
    state.expanded.add(p);
    p = state.indexed.parentOf.get(p);
  }
}

function joinPath(root, rel) {
  if (rel === '.' || rel === '') return root;
  return root.replace(/\/+$/, '') + '/' + rel;
}

// -- selection helpers ------------------------------------------------------

function editablePaths() {
  return [...state.selection.entries()].filter(([, k]) => k === 'editable').map(([p]) => p);
}
function readOnlyPaths() {
  return [...state.selection.entries()].filter(([, k]) => k === 'readonly').map(([p]) => p);
}

function setSelection(path, kind) {
  const others = [...state.selection.keys()].filter((p) => p !== path);
  if (kind && findCoveringPath(path, others)) {
    showToast("Can't select that — it overlaps an existing selection.", true);
    return;
  }
  if (kind === null) {
    state.selection.delete(path);
    if (state.primary === path) state.primary = null;
  } else {
    state.selection.set(path, kind);
  }
  renderTree();
  renderManifest();
  refreshCommand();
}

// -- tree rendering ------------------------------------------------------

function computeVisibleRows() {
  const filter = state.filterText.trim().toLowerCase();
  const searching = filter.length > 0;
  const matchCache = new Map();

  function matchesSubtree(node) {
    if (matchCache.has(node.path)) return matchCache.get(node.path);
    let result = node.name.toLowerCase().includes(filter);
    if (!result) {
      const kids = state.indexed.childrenOf.get(node.path) || [];
      result = kids.some((k) => matchesSubtree(state.indexed.byPath.get(k)));
    }
    matchCache.set(node.path, result);
    return result;
  }

  function gitOk(node) {
    return !state.gitOnly || state.hasGitDescendant.get(node.path);
  }

  const rows = [];
  function walk(node) {
    if (!gitOk(node)) return;
    if (searching && !matchesSubtree(node)) return;
    rows.push(node);
    const isExpanded = searching || node.depth === 0 || state.expanded.has(node.path);
    if (isExpanded) {
      const kids = state.indexed.childrenOf.get(node.path) || [];
      for (const kPath of kids) walk(state.indexed.byPath.get(kPath));
    }
  }

  const root = state.tree[0];
  if (root) walk(root);
  return rows;
}

function segButton(val, label, active, disabled, onClick) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'seg-btn' + (active ? ' active' : '');
  b.dataset.val = val;
  b.textContent = label;
  b.disabled = disabled;
  b.addEventListener('click', (e) => {
    e.stopPropagation();
    onClick();
  });
  return b;
}

async function revealInFinder(dirPath) {
  try {
    await apiFetch('/api/reveal', { method: 'POST', body: JSON.stringify({ path: dirPath }) });
  } catch (err) {
    showToast(err.message, true);
  }
}

function renderTree() {
  const rows = computeVisibleRows();
  state.visibleRows = rows;
  if (state.cursor >= rows.length) state.cursor = Math.max(0, rows.length - 1);

  const el = document.getElementById('treeList');
  el.innerHTML = '';

  if (rows.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'empty-hint';
    empty.style.padding = '12px';
    empty.textContent = 'No folders match.';
    el.appendChild(empty);
    return;
  }

  const selectedPaths = [...state.selection.keys()];

  rows.forEach((node, i) => {
    const row = document.createElement('div');
    row.className = 'tree-row';
    row.setAttribute('role', 'option');
    row.style.paddingLeft = `${8 + node.depth * 16}px`;
    if (i === state.cursor) row.classList.add('cursor');

    const sel = state.selection.get(node.path);
    if (sel) row.classList.add(`sel-${sel}`);

    const covering = !sel ? findCoveringPath(node.path, selectedPaths) : null;
    if (covering) row.classList.add('covered');

    const kids = state.indexed.childrenOf.get(node.path) || [];
    const hasKids = kids.length > 0;
    const isExpanded = state.filterText.trim() || node.depth === 0 || state.expanded.has(node.path);

    const disclosure = document.createElement('button');
    disclosure.type = 'button';
    disclosure.className = 'disclosure';
    disclosure.textContent = hasKids ? (isExpanded ? '▾' : '▸') : '';
    disclosure.disabled = !hasKids;
    disclosure.addEventListener('click', (e) => {
      e.stopPropagation();
      if (state.expanded.has(node.path)) state.expanded.delete(node.path);
      else state.expanded.add(node.path);
      renderTree();
    });
    row.appendChild(disclosure);

    const name = document.createElement('span');
    name.className = 'row-name';
    name.textContent = node.depth === 0 ? node.path : node.name;
    row.appendChild(name);

    if (node.isGitRepo) {
      const badge = document.createElement('span');
      badge.className = 'badge-git';
      badge.textContent = 'git';
      row.appendChild(badge);
    }
    if (node.unreadable) {
      const badge = document.createElement('span');
      badge.className = 'badge-unreadable';
      badge.textContent = 'unreadable';
      row.appendChild(badge);
    }
    if (covering) {
      const reason = document.createElement('span');
      reason.className = 'row-reason';
      reason.textContent = `covered by ${covering === state.tree[0]?.path ? 'root' : covering.split('/').pop()}`;
      row.appendChild(reason);
    }

    const controls = document.createElement('div');
    controls.className = 'row-controls';
    controls.appendChild(segButton('off', '–', sel === undefined, false, () => setSelection(node.path, null)));
    controls.appendChild(segButton('edit', 'edit', sel === 'editable', !!covering, () => setSelection(node.path, 'editable')));
    controls.appendChild(segButton('ro', 'ro', sel === 'readonly', !!covering, () => setSelection(node.path, 'readonly')));

    const revealBtn = document.createElement('button');
    revealBtn.type = 'button';
    revealBtn.className = 'seg-btn reveal-btn';
    revealBtn.textContent = 'finder';
    revealBtn.title = 'Open in Finder';
    revealBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      revealInFinder(node.path);
    });
    controls.appendChild(revealBtn);

    row.appendChild(controls);

    row.addEventListener('click', () => {
      state.cursor = i;
      renderTree();
    });

    el.appendChild(row);
  });
}

// -- manifest rendering ------------------------------------------------------

function manifestRow(p, kind, isPrimary) {
  const li = document.createElement('li');
  li.className = `manifest-row kind-${kind}`;

  const star = document.createElement('button');
  star.type = 'button';
  star.className = 'star-btn';
  star.textContent = isPrimary ? '★' : kind === 'editable' ? '☆' : '';
  star.title = kind === 'editable' ? 'Set as primary workspace' : '';
  star.disabled = kind !== 'editable';
  star.addEventListener('click', () => {
    state.primary = p;
    renderManifest();
    refreshCommand();
  });
  li.appendChild(star);

  const path = document.createElement('span');
  path.className = 'manifest-path';
  path.textContent = p + (kind === 'readonly' ? ':ro' : '');
  li.appendChild(path);

  const note = document.createElement('span');
  note.className = 'manifest-note';
  note.textContent = isPrimary ? 'primary' : kind === 'readonly' ? 'read-only' : '';
  li.appendChild(note);

  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'remove-btn';
  remove.textContent = '×';
  remove.setAttribute('aria-label', `Remove ${p}`);
  remove.addEventListener('click', () => setSelection(p, null));
  li.appendChild(remove);

  return li;
}

function renderManifest() {
  const list = document.getElementById('manifestList');
  const empty = document.getElementById('manifestEmpty');
  list.innerHTML = '';

  const editable = editablePaths();
  const readOnly = readOnlyPaths();
  const primary = resolvePrimary(editable, state.primary);

  if (editable.length === 0 && readOnly.length === 0) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;
  for (const p of [...editable].sort()) list.appendChild(manifestRow(p, 'editable', p === primary));
  for (const p of [...readOnly].sort()) list.appendChild(manifestRow(p, 'readonly', false));
}

// -- command preview ------------------------------------------------------

function refreshCommand() {
  const editable = editablePaths();
  const readOnly = readOnlyPaths();
  const el = document.getElementById('commandDisplay');
  const errEl = document.getElementById('commandError');
  const runBtn = document.getElementById('runBtn');
  const copyBtn = document.getElementById('copyBtn');
  const saveBtn = document.getElementById('saveBtn');

  try {
    const { display } = buildCommand({
      agent: state.config.agent,
      template: state.template || state.config.defaultTemplate,
      name: state.name,
      clone: state.clone,
      editable,
      readOnly,
      primary: state.primary,
    });
    el.textContent = display;
    errEl.hidden = true;
    runBtn.disabled = false;
    copyBtn.disabled = false;
    saveBtn.disabled = false;
  } catch (err) {
    el.textContent = '';
    errEl.textContent = err.message;
    errEl.hidden = false;
    runBtn.disabled = true;
    copyBtn.disabled = true;
    saveBtn.disabled = true;
  }
}

// -- API ------------------------------------------------------

async function apiFetch(urlPath, options = {}) {
  const res = await fetch(urlPath, {
    ...options,
    headers: { 'content-type': 'application/json', 'x-sbx-helper-token': state.token, ...(options.headers || {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `Request failed (${res.status})`);
  return body;
}

function applyTreeState(data) {
  state.config = data.config;
  state.tree = data.tree;
  reindex();
  document.getElementById('rootPath').textContent = state.config.rootPath;
}

// -- template select ------------------------------------------------------

function populateTemplateSelect() {
  const sel = document.getElementById('templateSelect');
  sel.innerHTML = '';
  const opts = [...new Set([state.config.defaultTemplate, ...state.templates])];
  for (const t of opts) {
    const o = document.createElement('option');
    o.value = t;
    o.textContent = t;
    sel.appendChild(o);
  }
  const customOpt = document.createElement('option');
  customOpt.value = '__custom__';
  customOpt.textContent = 'Custom…';
  sel.appendChild(customOpt);

  const templateCustom = document.getElementById('templateCustom');
  if (opts.includes(state.template)) {
    sel.value = state.template;
    templateCustom.hidden = true;
  } else {
    sel.value = '__custom__';
    templateCustom.hidden = false;
    templateCustom.value = state.template;
  }
}

async function persistTemplate() {
  try {
    await apiFetch('/api/config', { method: 'POST', body: JSON.stringify({ defaultTemplate: state.template }) });
  } catch {
    // Non-fatal — the session still has the right value in memory.
  }
}

// -- toast ------------------------------------------------------

let toastTimer = null;
function showToast(msg, isError = false) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.toggle('toast-error', !!isError);
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    el.hidden = true;
  }, 3500);
}

// -- actions ------------------------------------------------------

async function doCopy() {
  const text = document.getElementById('commandDisplay').textContent;
  if (!text) return;
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
    } else {
      await apiFetch('/api/clipboard', { method: 'POST', body: JSON.stringify({ text }) });
    }
    showToast('Copied to clipboard.');
  } catch {
    try {
      await apiFetch('/api/clipboard', { method: 'POST', body: JSON.stringify({ text }) });
      showToast('Copied to clipboard.');
    } catch (err) {
      showToast(`Could not copy: ${err.message}`, true);
    }
  }
}

async function doRun() {
  const editable = editablePaths();
  const readOnly = readOnlyPaths();
  if (editable.length === 0) {
    showToast('Select at least one editable folder first.', true);
    return;
  }
  const runBtn = document.getElementById('runBtn');
  const originalLabel = runBtn.textContent;
  runBtn.disabled = true;
  runBtn.textContent = 'Launching…';
  try {
    await apiFetch('/api/run', {
      method: 'POST',
      body: JSON.stringify({
        editable,
        readOnly,
        primary: state.primary,
        template: state.template || state.config.defaultTemplate,
        name: state.name,
        clone: state.clone,
      }),
    });
    showToast('Launched in a new terminal window.');
  } catch (err) {
    showToast(err.message, true);
  } finally {
    runBtn.disabled = false;
    runBtn.textContent = originalLabel;
  }
}

// -- root dialog ------------------------------------------------------
//
// The list under the input does double duty: with nothing typed (or on
// open) it shows recent roots; as soon as the user edits the field, it
// switches to live filesystem suggestions for whatever they're typing.

let pathSuggestions = [];
let suggestionIndex = -1;
let suggestionDebounce = null;

function renderSuggestionList(items) {
  const ul = document.getElementById('recentRootsList');
  ul.innerHTML = '';
  items.forEach((p, i) => {
    const li = document.createElement('li');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'recent-root-btn' + (i === suggestionIndex ? ' highlighted' : '');
    btn.textContent = p;
    btn.addEventListener('click', () => acceptSuggestion(p));
    li.appendChild(btn);
    ul.appendChild(li);
  });
}

function renderRecentRoots() {
  pathSuggestions = state.config.recentRoots || [];
  suggestionIndex = -1;
  renderSuggestionList(pathSuggestions);
}

async function updatePathSuggestions() {
  const value = document.getElementById('rootInput').value;
  if (!value.trim()) {
    renderRecentRoots();
    return;
  }
  try {
    const data = await apiFetch(`/api/complete-path?prefix=${encodeURIComponent(value)}`);
    pathSuggestions = data.suggestions || [];
    suggestionIndex = -1;
    renderSuggestionList(pathSuggestions);
  } catch {
    // Non-fatal — leave whatever suggestions are already showing.
  }
}

function acceptSuggestion(p) {
  const input = document.getElementById('rootInput');
  input.value = p.endsWith('/') ? p : p + '/';
  input.focus();
  updatePathSuggestions();
}

function openRootDialog() {
  const input = document.getElementById('rootInput');
  input.value = state.config.rootPath;
  document.getElementById('rootError').hidden = true;
  renderRecentRoots();
  document.getElementById('rootDialog').showModal();
  input.focus();
  input.select();
}

function bindRootDialog() {
  const input = document.getElementById('rootInput');
  const errEl = document.getElementById('rootError');

  input.addEventListener('input', () => {
    clearTimeout(suggestionDebounce);
    suggestionDebounce = setTimeout(updatePathSuggestions, 120);
  });

  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') {
      if (pathSuggestions.length === 0) return;
      e.preventDefault();
      suggestionIndex = Math.min(pathSuggestions.length - 1, suggestionIndex + 1);
      renderSuggestionList(pathSuggestions);
    } else if (e.key === 'ArrowUp') {
      if (pathSuggestions.length === 0) return;
      e.preventDefault();
      suggestionIndex = Math.max(-1, suggestionIndex - 1);
      renderSuggestionList(pathSuggestions);
    } else if (e.key === 'Tab' && suggestionIndex === -1 && pathSuggestions.length > 0) {
      e.preventDefault();
      acceptSuggestion(pathSuggestions[0]);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (suggestionIndex >= 0 && pathSuggestions[suggestionIndex]) {
        acceptSuggestion(pathSuggestions[suggestionIndex]);
      } else {
        document.getElementById('confirmRootBtn').click();
      }
    }
  });

  document.getElementById('cancelRootBtn').addEventListener('click', () => document.getElementById('rootDialog').close());
  document.getElementById('confirmRootBtn').addEventListener('click', async () => {
    try {
      const data = await apiFetch('/api/scan', { method: 'POST', body: JSON.stringify({ rootPath: input.value.trim() }) });
      applyTreeState(data);
      state.selection.clear();
      state.primary = null;
      state.expanded.clear();
      state.cursor = 0;
      state.filterText = '';
      document.getElementById('filterInput').value = '';
      renderTree();
      renderManifest();
      refreshCommand();
      document.getElementById('rootDialog').close();
    } catch (err) {
      errEl.textContent = err.message;
      errEl.hidden = false;
    }
  });
}

// -- save preset dialog ------------------------------------------------------

function openSaveDialog() {
  document.getElementById('presetNameInput').value = '';
  document.getElementById('saveError').hidden = true;
  document.getElementById('saveDialog').showModal();
  document.getElementById('presetNameInput').focus();
}

function bindSaveDialog() {
  document.getElementById('cancelSaveBtn').addEventListener('click', () => document.getElementById('saveDialog').close());
  document.getElementById('confirmSaveBtn').addEventListener('click', async () => {
    const name = document.getElementById('presetNameInput').value.trim();
    const errEl = document.getElementById('saveError');
    if (!name) {
      errEl.textContent = 'Name is required.';
      errEl.hidden = false;
      return;
    }
    try {
      const data = await apiFetch('/api/presets', {
        method: 'POST',
        body: JSON.stringify({
          action: 'save',
          name,
          editable: editablePaths(),
          readOnly: readOnlyPaths(),
          template: state.template,
          sandboxName: state.name || null,
          clone: state.clone,
        }),
      });
      state.config.presets = data.presets;
      document.getElementById('saveDialog').close();
      showToast(data.overwritten ? `Preset "${name}" overwritten.` : `Preset "${name}" saved.`);
    } catch (err) {
      errEl.textContent = err.message;
      errEl.hidden = false;
    }
  });
}

// -- presets dialog ------------------------------------------------------

function renderPresetsDialog() {
  const ul = document.getElementById('presetsListDialog');
  ul.innerHTML = '';
  const presets = state.config.presets || [];
  if (presets.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty-hint';
    li.textContent = 'No saved presets yet.';
    ul.appendChild(li);
    return;
  }
  for (const p of presets) {
    const li = document.createElement('li');
    li.className = 'preset-row';

    const info = document.createElement('div');
    info.className = 'preset-info';
    const name = document.createElement('div');
    name.className = 'preset-name';
    name.textContent = p.name;
    const meta = document.createElement('div');
    meta.className = 'preset-meta';
    meta.textContent = `${p.template} · ${p.editable.length} editable, ${p.readOnly.length} read-only · ${p.rootPath}`;
    info.appendChild(name);
    info.appendChild(meta);
    li.appendChild(info);

    const loadBtn = document.createElement('button');
    loadBtn.type = 'button';
    loadBtn.className = 'btn';
    loadBtn.textContent = 'Load';
    loadBtn.addEventListener('click', () => loadPreset(p));
    li.appendChild(loadBtn);

    const delBtn = document.createElement('button');
    delBtn.type = 'button';
    delBtn.className = 'btn btn-danger';
    delBtn.textContent = 'Delete';
    delBtn.addEventListener('click', () => deletePreset(p.name));
    li.appendChild(delBtn);

    ul.appendChild(li);
  }
}

async function loadPreset(p) {
  try {
    if (p.rootPath !== state.config.rootPath) {
      const data = await apiFetch('/api/scan', { method: 'POST', body: JSON.stringify({ rootPath: p.rootPath }) });
      applyTreeState(data);
    }

    state.selection.clear();
    state.expanded.clear();
    for (const rel of p.editable) {
      const abs = joinPath(p.rootPath, rel);
      state.selection.set(abs, 'editable');
      expandAncestors(abs);
    }
    for (const rel of p.readOnly) {
      const abs = joinPath(p.rootPath, rel);
      state.selection.set(abs, 'readonly');
      expandAncestors(abs);
    }
    state.primary = null;

    state.template = p.template;
    populateTemplateSelect();

    state.name = p.sandboxName || '';
    document.getElementById('nameInput').value = state.name;

    state.clone = !!p.clone;
    document.getElementById('cloneToggle').checked = state.clone;

    state.cursor = 0;
    renderTree();
    renderManifest();
    refreshCommand();
    document.getElementById('presetsDialog').close();
    showToast(`Loaded preset "${p.name}".`);
  } catch (err) {
    showToast(err.message, true);
  }
}

async function deletePreset(name) {
  try {
    const data = await apiFetch('/api/presets', { method: 'POST', body: JSON.stringify({ action: 'delete', name }) });
    state.config.presets = data.presets;
    renderPresetsDialog();
    showToast(`Deleted preset "${name}".`);
  } catch (err) {
    showToast(err.message, true);
  }
}

function bindPresetsDialog() {
  document.getElementById('presetsBtn').addEventListener('click', () => {
    renderPresetsDialog();
    document.getElementById('presetsDialog').showModal();
  });
  document.getElementById('closePresetsBtn').addEventListener('click', () => document.getElementById('presetsDialog').close());
}

// -- sandboxes tab ------------------------------------------------------

function currentSandbox() {
  return state.sandboxes.find((s) => s.name === state.selectedSandbox) || null;
}

function statusDotClass(status) {
  if (status === 'running') return 'status-running';
  if (status === 'stopped') return 'status-stopped';
  return 'status-other';
}

function defaultArgsTextFor(sandbox) {
  const stored = state.config?.sandboxArgs?.[sandbox.name];
  if (typeof stored === 'string') return stored;
  return formatCommand(defaultAgentArgs(sandbox.agent));
}

/** The one place the sandbox list is stored — re-validates the current
 * selection against it, since a refresh gives every sandbox a new object
 * identity and the selected one may no longer exist at all. */
function applySandboxes(list) {
  state.sandboxes = list;
  if (state.selectedSandbox && !list.some((s) => s.name === state.selectedSandbox)) {
    state.selectedSandbox = null;
    state.policyRules = [];
    state.policiesFor = null;
  }
}

async function fetchSandboxes() {
  try {
    const data = await apiFetch('/api/sandboxes');
    applySandboxes(data.sandboxes || []);
    state.sandboxesError = null;
  } catch (err) {
    applySandboxes([]);
    state.sandboxesError = err.message;
  }
  state.sandboxesLoaded = true;
  renderSandboxList();
  renderSandboxDetail();
}

async function fetchPolicies(name) {
  state.policyRules = [];
  state.policiesFor = null;
  renderPolicies();
  try {
    const data = await apiFetch(`/api/sandbox-policies?name=${encodeURIComponent(name)}`);
    state.policyRules = data.rules || [];
    state.policiesFor = name;
  } catch (err) {
    showToast(err.message, true);
  }
  renderPolicies();
}

function selectSandbox(name) {
  if (state.selectedSandbox === name) return;
  state.selectedSandbox = name;
  renderSandboxList();
  renderSandboxDetail();
  fetchPolicies(name);
}

function renderSandboxList() {
  const el = document.getElementById('sandboxList');
  const empty = document.getElementById('sandboxListEmpty');
  const errEl = document.getElementById('sandboxListError');
  const countEl = document.getElementById('sandboxCount');
  el.innerHTML = '';

  errEl.hidden = !state.sandboxesError;
  if (state.sandboxesError) errEl.textContent = state.sandboxesError;

  empty.hidden = !(state.sandboxesLoaded && !state.sandboxesError && state.sandboxes.length === 0);

  countEl.textContent = state.sandboxesLoaded
    ? `${state.sandboxes.length} sandbox${state.sandboxes.length === 1 ? '' : 'es'}`
    : '';

  for (const sandbox of state.sandboxes) {
    const row = document.createElement('div');
    row.className = 'sandbox-row';
    row.setAttribute('role', 'radio');
    row.setAttribute('aria-checked', String(state.selectedSandbox === sandbox.name));

    const dot = document.createElement('span');
    dot.className = `status-dot ${statusDotClass(sandbox.status)}`;
    dot.title = sandbox.status;
    row.appendChild(dot);

    const name = document.createElement('span');
    name.className = 'sandbox-name';
    name.textContent = sandbox.name;
    row.appendChild(name);

    const agent = document.createElement('span');
    agent.className = 'sandbox-agent';
    agent.textContent = sandbox.agent;
    row.appendChild(agent);

    const ports = document.createElement('span');
    ports.className = 'sandbox-meta';
    ports.textContent = (sandbox.ports || []).map(formatPort).join(', ') || '—';
    row.appendChild(ports);

    const workspaces = document.createElement('span');
    workspaces.className = 'sandbox-meta';
    workspaces.textContent = (sandbox.workspaces || []).join(', ');
    workspaces.title = workspaces.textContent;
    row.appendChild(workspaces);

    row.addEventListener('click', () => selectSandbox(sandbox.name));
    el.appendChild(row);
  }
}

function renderSandboxDetail() {
  const sandbox = currentSandbox();
  const emptyEl = document.getElementById('sandboxDetailEmpty');
  const detailEl = document.getElementById('sandboxDetailSection');
  const runSection = document.getElementById('sandboxRunSection');
  const policySection = document.getElementById('policySection');

  if (!sandbox) {
    emptyEl.hidden = false;
    detailEl.hidden = true;
    runSection.hidden = true;
    policySection.hidden = true;
    return;
  }
  emptyEl.hidden = true;
  detailEl.hidden = false;
  runSection.hidden = false;
  policySection.hidden = false;

  const dl = document.getElementById('sandboxSummary');
  dl.innerHTML = '';
  const rows = [
    ['name', sandbox.name],
    ['agent', sandbox.agent],
    ['status', sandbox.status],
    ['ports', (sandbox.ports || []).map(formatPort).join(', ') || '—'],
    ['workspace', (sandbox.workspaces || []).join(', ') || '—'],
  ];
  for (const [k, v] of rows) {
    const dt = document.createElement('dt');
    dt.textContent = k;
    const dd = document.createElement('dd');
    dd.textContent = v;
    dl.appendChild(dt);
    dl.appendChild(dd);
  }

  if (!state.sandboxArgsText.has(sandbox.name)) {
    state.sandboxArgsText.set(sandbox.name, defaultArgsTextFor(sandbox));
  }
  document.getElementById('sandboxArgsInput').value = state.sandboxArgsText.get(sandbox.name);

  document.getElementById('sandboxStopBtn').disabled = sandbox.status !== 'running' || state.sandboxBusy;
  document.getElementById('sandboxDeleteBtn').disabled = state.sandboxBusy;

  refreshSandboxCommand();
}

function refreshSandboxCommand() {
  const sandbox = currentSandbox();
  if (!sandbox) return;

  const text = document.getElementById('sandboxArgsInput').value;
  state.sandboxArgsText.set(sandbox.name, text);

  const display = document.getElementById('sandboxCommandDisplay');
  const errEl = document.getElementById('sandboxCommandError');
  const runBtn = document.getElementById('sandboxRunBtn');

  try {
    const agentArgs = tokenizeArgs(text);
    const args = buildRunExistingArgs({ name: sandbox.name, agentArgs });
    display.textContent = formatCommand(args);
    errEl.hidden = true;
    runBtn.disabled = state.sandboxBusy;
  } catch (err) {
    display.textContent = '';
    errEl.textContent = err.message;
    errEl.hidden = false;
    runBtn.disabled = true;
  }
}

function renderPolicies() {
  const list = document.getElementById('policyList');
  const summary = document.getElementById('policySummary');
  list.innerHTML = '';

  if (!state.selectedSandbox) {
    summary.textContent = '';
    return;
  }

  const rules = state.policyRules;
  if (state.policiesFor !== state.selectedSandbox) {
    summary.textContent = 'Loading…';
    return;
  }

  const scopedCount = rules.filter((r) => r.sandboxScoped).length;
  const denyCount = rules.filter((r) => r.decision === 'deny').length;
  summary.textContent = `${rules.length} rule${rules.length === 1 ? '' : 's'} apply · ${scopedCount} scoped to this sandbox · ${denyCount} deny`;

  for (const rule of rules) {
    const li = document.createElement('li');
    li.className = 'policy-row' + (rule.sandboxScoped ? '' : ' scope-global');

    const head = document.createElement('div');
    head.className = 'policy-row-head';

    const decision = document.createElement('span');
    decision.className = 'policy-decision' + (rule.decision === 'deny' ? ' deny' : '');
    decision.textContent = rule.decision;
    head.appendChild(decision);

    const scopeLabel = document.createElement('span');
    scopeLabel.className = 'policy-scope-label';
    scopeLabel.textContent = rule.sandboxScoped ? 'this sandbox' : rule.origin === 'scoped' ? 'kit' : 'global';
    head.appendChild(scopeLabel);

    if (rule.removable) {
      const removeBtn = document.createElement('button');
      removeBtn.type = 'button';
      removeBtn.className = 'remove-btn';
      removeBtn.textContent = '×';
      removeBtn.title = 'Remove this rule';
      removeBtn.setAttribute('aria-label', `Remove rule for ${rule.resources.join(', ')}`);
      removeBtn.addEventListener('click', () => doPolicyRemove(rule));
      head.appendChild(removeBtn);
    }
    li.appendChild(head);

    const resources = document.createElement('div');
    resources.className = 'policy-resources';
    for (const resource of rule.resources) {
      const chip = document.createElement('span');
      chip.className = 'policy-chip';
      chip.textContent = resource;
      resources.appendChild(chip);
    }
    li.appendChild(resources);

    list.appendChild(li);
  }
}

async function doSandboxStop() {
  const sandbox = currentSandbox();
  if (!sandbox) return;
  state.sandboxBusy = true;
  renderSandboxDetail();
  try {
    await apiFetch('/api/sandbox/stop', { method: 'POST', body: JSON.stringify({ name: sandbox.name }) });
    showToast(`Stopped ${sandbox.name}.`);
    await fetchSandboxes();
  } catch (err) {
    showToast(err.message, true);
  } finally {
    state.sandboxBusy = false;
    renderSandboxDetail();
  }
}

async function doSandboxRun() {
  const sandbox = currentSandbox();
  if (!sandbox) return;
  const text = document.getElementById('sandboxArgsInput').value;
  const agentArgs = tokenizeArgs(text);

  // Mirrors the server exactly — same tokenize-then-formatCommand string,
  // updated unconditionally rather than only after a successful launch.
  // Storing the raw textarea text instead would drift from what's actually
  // on disk the moment a value with, say, double quotes gets normalized to
  // formatCommand's canonical single-quoted form on the next reload. And a
  // failed launch (no terminal app available, say) isn't a reason to
  // discard what the user typed, so this happens before the request, not
  // only in the success branch.
  state.config.sandboxArgs = state.config.sandboxArgs || {};
  if (agentArgs.length > 0) state.config.sandboxArgs[sandbox.name] = formatCommand(agentArgs);
  else delete state.config.sandboxArgs[sandbox.name];

  state.sandboxBusy = true;
  renderSandboxDetail();
  try {
    await apiFetch('/api/sandbox/run', { method: 'POST', body: JSON.stringify({ name: sandbox.name, args: agentArgs }) });
    showToast('Launched in a new terminal window.');
  } catch (err) {
    showToast(err.message, true);
  } finally {
    state.sandboxBusy = false;
    renderSandboxDetail();
  }
}

function openDeleteSandboxDialog() {
  const sandbox = currentSandbox();
  if (!sandbox) return;
  document.getElementById('deleteSandboxMessage').textContent =
    `Delete "${sandbox.name}"? Workspaces: ${(sandbox.workspaces || []).join(', ') || '—'}`;
  document.getElementById('deleteSandboxError').hidden = true;
  document.getElementById('deleteSandboxDialog').showModal();
}

async function confirmDeleteSandbox() {
  const sandbox = currentSandbox();
  if (!sandbox) return;
  const errEl = document.getElementById('deleteSandboxError');
  const btn = document.getElementById('confirmDeleteSandboxBtn');
  btn.disabled = true;
  try {
    await apiFetch('/api/sandbox/remove', { method: 'POST', body: JSON.stringify({ name: sandbox.name }) });
    document.getElementById('deleteSandboxDialog').close();
    showToast(`Deleted ${sandbox.name}.`);
    state.selectedSandbox = null;
    state.sandboxArgsText.delete(sandbox.name);
    await fetchSandboxes();
    renderSandboxDetail();
  } catch (err) {
    errEl.textContent = err.message;
    errEl.hidden = false;
  } finally {
    btn.disabled = false;
  }
}

function bindDeleteSandboxDialog() {
  document.getElementById('sandboxDeleteBtn').addEventListener('click', openDeleteSandboxDialog);
  document.getElementById('cancelDeleteSandboxBtn').addEventListener('click', () => document.getElementById('deleteSandboxDialog').close());
  document.getElementById('confirmDeleteSandboxBtn').addEventListener('click', confirmDeleteSandbox);
}

async function doPolicyAdd() {
  if (!state.selectedSandbox) return;
  const decision = document.getElementById('policyDecisionSelect').value;
  const resourceInput = document.getElementById('policyResourceInput');
  const errEl = document.getElementById('policyError');
  const resources = parseResourceList(resourceInput.value);

  if (resources.length === 0) {
    errEl.textContent = 'Enter at least one resource.';
    errEl.hidden = false;
    return;
  }
  if (resources.length > MAX_RESOURCES_PER_REQUEST) {
    errEl.textContent = `Too many resources at once (max ${MAX_RESOURCES_PER_REQUEST}) — split them into multiple additions.`;
    errEl.hidden = false;
    return;
  }
  const invalid = resources.find((r) => !isValidNetworkResource(r));
  if (invalid) {
    errEl.textContent = `Not a valid resource: ${invalid}`;
    errEl.hidden = false;
    return;
  }
  errEl.hidden = true;

  try {
    const data = await apiFetch('/api/sandbox/policy', {
      method: 'POST',
      body: JSON.stringify({ name: state.selectedSandbox, action: 'add', decision, resources }),
    });
    state.policyRules = data.rules || [];
    state.policiesFor = state.selectedSandbox;
    renderPolicies();
    resourceInput.value = '';
    showToast('Rule added.');
  } catch (err) {
    errEl.textContent = err.message;
    errEl.hidden = false;
  }
}

async function doPolicyRemove(rule) {
  if (!state.selectedSandbox) return;
  try {
    const data = await apiFetch('/api/sandbox/policy', {
      method: 'POST',
      body: JSON.stringify({ name: state.selectedSandbox, action: 'remove', ruleId: rule.id }),
    });
    state.policyRules = data.rules || [];
    state.policiesFor = state.selectedSandbox;
    renderPolicies();
    showToast('Rule removed.');
  } catch (err) {
    showToast(err.message, true);
  }
}

// -- tabs ------------------------------------------------------

function setActiveTab(tab) {
  if (state.activeTab === tab) return;
  state.activeTab = tab;

  const onBuilder = tab === 'builder';
  document.getElementById('builderPanel').hidden = !onBuilder;
  document.getElementById('sandboxesPanel').hidden = onBuilder;
  document.getElementById('builderTopbarControls').hidden = !onBuilder;
  document.getElementById('sandboxesTopbarControls').hidden = onBuilder;
  document.getElementById('tabBuilderBtn').setAttribute('aria-selected', String(onBuilder));
  document.getElementById('tabSandboxesBtn').setAttribute('aria-selected', String(!onBuilder));

  if (!onBuilder && !state.sandboxesLoaded) fetchSandboxes();
}

function bindTabs() {
  document.getElementById('tabBuilderBtn').addEventListener('click', () => setActiveTab('builder'));
  document.getElementById('tabSandboxesBtn').addEventListener('click', () => setActiveTab('sandboxes'));

  // Standard ARIA tabs keyboard pattern: left/right move focus and
  // selection between tabs when a tab button itself has focus.
  document.querySelector('.tabs').addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault();
    const next = state.activeTab === 'builder' ? 'sandboxes' : 'builder';
    setActiveTab(next);
    document.getElementById(next === 'builder' ? 'tabBuilderBtn' : 'tabSandboxesBtn').focus();
  });
}

function bindSandboxesTab() {
  document.getElementById('refreshSandboxesBtn').addEventListener('click', () => fetchSandboxes());
  document.getElementById('sandboxArgsInput').addEventListener('input', refreshSandboxCommand);
  document.getElementById('sandboxRunBtn').addEventListener('click', doSandboxRun);
  document.getElementById('sandboxStopBtn').addEventListener('click', doSandboxStop);
  document.getElementById('policyAddBtn').addEventListener('click', doPolicyAdd);
  bindDeleteSandboxDialog();
}

// -- keyboard ------------------------------------------------------

function scrollCursorIntoView() {
  document.querySelector('.tree-row.cursor')?.scrollIntoView({ block: 'nearest' });
}

// Dispatches to the active tab's handler. Each tab owns its own shortcuts
// (the builder's `/`, `e`, `r`, arrows have no equivalent meaning on the
// Sandboxes tab, and vice versa) so switching tabs can't leave a stale
// shortcut armed.
function onGlobalKeydown(e) {
  if (document.querySelector('dialog[open]')) return; // dialogs own their own keys
  if (state.activeTab === 'sandboxes') return onSandboxesKeydown(e);
  return onBuilderKeydown(e);
}

function onBuilderKeydown(e) {
  const tag = document.activeElement?.tagName;
  const typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';

  if (e.key === '/' && !typing) {
    e.preventDefault();
    document.getElementById('filterInput').focus();
    return;
  }
  if (e.key === 'Enter' && e.metaKey) {
    e.preventDefault();
    doRun();
    return;
  }
  if (typing) return;

  const rows = state.visibleRows;
  if (e.key === 'ArrowDown') {
    e.preventDefault();
    state.cursor = Math.min(rows.length - 1, state.cursor + 1);
    renderTree();
    scrollCursorIntoView();
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    state.cursor = Math.max(0, state.cursor - 1);
    renderTree();
    scrollCursorIntoView();
  } else if (e.key === 'ArrowRight') {
    const node = rows[state.cursor];
    if (node && (state.indexed.childrenOf.get(node.path) || []).length) {
      state.expanded.add(node.path);
      renderTree();
    }
  } else if (e.key === 'ArrowLeft') {
    const node = rows[state.cursor];
    if (node && state.expanded.has(node.path)) {
      state.expanded.delete(node.path);
      renderTree();
    }
  } else if (e.key === 'e' || e.key === 'E') {
    const node = rows[state.cursor];
    if (node) setSelection(node.path, state.selection.get(node.path) === 'editable' ? null : 'editable');
  } else if (e.key === 'r' || e.key === 'R') {
    const node = rows[state.cursor];
    if (node) setSelection(node.path, state.selection.get(node.path) === 'readonly' ? null : 'readonly');
  }
}

function onSandboxesKeydown(e) {
  const tag = document.activeElement?.tagName;
  const typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';

  if (e.key === 'Enter' && e.metaKey) {
    e.preventDefault();
    doSandboxRun();
    return;
  }
  if (typing) return;

  if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && state.sandboxes.length > 0) {
    e.preventDefault();
    const idx = state.sandboxes.findIndex((s) => s.name === state.selectedSandbox);
    const nextIdx =
      idx === -1 ? 0 : e.key === 'ArrowDown' ? Math.min(state.sandboxes.length - 1, idx + 1) : Math.max(0, idx - 1);
    selectSandbox(state.sandboxes[nextIdx].name);
  }
}

// -- wiring ------------------------------------------------------

function bindEvents() {
  const filterInput = document.getElementById('filterInput');
  filterInput.addEventListener('input', () => {
    state.filterText = filterInput.value;
    state.cursor = 0;
    renderTree();
  });

  document.getElementById('gitOnlyToggle').addEventListener('change', (e) => {
    state.gitOnly = e.target.checked;
    state.cursor = 0;
    renderTree();
  });

  const templateSelect = document.getElementById('templateSelect');
  const templateCustom = document.getElementById('templateCustom');
  templateSelect.addEventListener('change', () => {
    if (templateSelect.value === '__custom__') {
      templateCustom.hidden = false;
      templateCustom.value = state.template;
      templateCustom.focus();
    } else {
      templateCustom.hidden = true;
      state.template = templateSelect.value;
      persistTemplate();
      refreshCommand();
    }
  });
  templateCustom.addEventListener('change', () => {
    state.template = templateCustom.value.trim() || state.config.defaultTemplate;
    persistTemplate();
    refreshCommand();
  });

  document.getElementById('nameInput').addEventListener('input', (e) => {
    state.name = e.target.value;
    refreshCommand();
  });

  document.getElementById('cloneToggle').addEventListener('change', (e) => {
    state.clone = e.target.checked;
    refreshCommand();
  });

  document.getElementById('copyBtn').addEventListener('click', doCopy);
  document.getElementById('runBtn').addEventListener('click', doRun);
  document.getElementById('saveBtn').addEventListener('click', openSaveDialog);
  document.getElementById('changeRootBtn').addEventListener('click', openRootDialog);

  bindRootDialog();
  bindSaveDialog();
  bindPresetsDialog();
  bindTabs();
  bindSandboxesTab();

  document.addEventListener('keydown', onGlobalKeydown);
}

// -- init ------------------------------------------------------

async function init() {
  const data = await apiFetch('/api/state');
  applyTreeState(data);
  state.templates = data.templates;
  state.template = data.config.defaultTemplate;

  // Now that the token has proven itself against a real request and is
  // cached in sessionStorage (so a later reload can still find it), scrub
  // it out of the visible URL/history — it's a bearer credential for this
  // server, and there's no reason for it to sit in the address bar or the
  // window title for as long as the tab is open.
  try {
    sessionStorage.setItem('sbxHelperToken', state.token);
    history.replaceState(null, '', location.pathname);
  } catch {
    // Non-fatal — cosmetic only (and sessionStorage may be unavailable).
  }

  populateTemplateSelect();
  renderTree();
  renderManifest();
  refreshCommand();
  bindEvents();
}

init().catch((err) => {
  showToast(err.message, true);
  // eslint-disable-next-line no-console
  console.error(err);
});

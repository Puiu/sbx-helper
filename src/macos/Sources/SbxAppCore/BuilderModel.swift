import Foundation
import Observation
import SbxKit
import SbxServices

/// Builder tab state: the scanned tree, filter/git-only/expansion, and the
/// async scan coordination that drives them (PLAN.md's Phase 3 state model).
@MainActor
@Observable
public final class BuilderModel {
    private let scanner: TreeScanning
    private let toasts: ToastCenter
    private let templateLister: TemplateListing
    private let launcher: TerminalLaunching
    private let clipboard: ClipboardWriting
    private let persistTemplate: @Sendable (String) async -> Void
    private let mutateConfig: @Sendable (@escaping @Sendable (inout AppConfig) -> Void) async -> Void
    private let pathExists: @Sendable (String) -> Bool
    private let pathIsDirectory: @Sendable (String) -> Bool
    private let revealer: FinderRevealing
    private let spinnerDelay: Duration

    public private(set) var tree: ScannedTree = .empty
    public private(set) var rootPath: String = ""
    public var filterText: String = ""
    public var gitOnly: Bool = false
    public private(set) var expanded: Set<String> = []
    public var cursor: String?
    public private(set) var isScanning: Bool = false

    // path -> kind. Absence of a key is the third ("off") state — mirrors
    // app.js's `state.selection` Map exactly (see SelectionKind.swift).
    public private(set) var selection: [String: SelectionKind] = [:]
    // Explicit override, or nil for the resolved default. Ports
    // app.js:41-42's `state.primary`.
    public private(set) var primary: String?
    // `selection.keys` in JS-ordinal order, kept up to date at `selection`'s two
    // mutation sites (setSelection, scan's root-change reset) rather than
    // recomputed on every `coveringPath(for:)` call — that call happens
    // once per visible tree row on every render, so re-sorting there scales
    // with tree size for no reason.
    private var sortedSelectionKeys: [String] = []

    // Template/name/clone — app.js's state.template/state.name/state.clone.
    public var template: String = ""
    public var sandboxName: String = ""
    public var clone: Bool = false
    public private(set) var templates: [String] = []
    public private(set) var agent: String = ""
    public private(set) var defaultTemplate: String = ""
    public private(set) var isLaunching: Bool = false

    private var scanGeneration = 0
    private var currentScanTask: Task<Void, Never>?
    private var currentSpinnerTask: Task<Void, Never>?
    // Every scan/spinner task currently running, keyed so each one can
    // remove itself on completion (a `Task` has no public "is it done" you
    // can poll, so self-removal via a captured key is what keeps this from
    // growing without bound in production — nothing there ever calls
    // `quiesce()`; only tests do, for deterministic teardown).
    private var inFlightTasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    // A preset loaded for a *different* root can't apply its selection until
    // the rescan lands (the tree it expands against doesn't exist yet), so
    // loadPreset stashes it here and the winning scan task consumes it. The
    // scan's own root is stored alongside because resolveRoot normalizes
    // (e.g. trailing slashes), and the consumer must compare against the
    // normalized root, not the preset's raw string.
    private var pendingPresetApply: (preset: Preset, root: String)?

    public init(
        scanner: TreeScanning,
        toasts: ToastCenter,
        templateLister: TemplateListing,
        launcher: TerminalLaunching,
        clipboard: ClipboardWriting,
        persistTemplate: @escaping @Sendable (String) async -> Void,
        pathExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        mutateConfig: @escaping @Sendable (@escaping @Sendable (inout AppConfig) -> Void) async -> Void = { _ in },
        revealer: FinderRevealing = SystemFinder(),
        pathIsDirectory: @escaping @Sendable (String) -> Bool = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        },
        spinnerDelay: Duration = .milliseconds(150)
    ) {
        self.scanner = scanner
        self.toasts = toasts
        self.templateLister = templateLister
        self.launcher = launcher
        self.clipboard = clipboard
        self.persistTemplate = persistTemplate
        self.pathExists = pathExists
        self.mutateConfig = mutateConfig
        self.revealer = revealer
        self.pathIsDirectory = pathIsDirectory
        self.spinnerDelay = spinnerDelay
    }

    /// Takes `agent` and `defaultTemplate` from the loaded config, and seeds
    /// `template` from the default only if the user hasn't already chosen
    /// one — mirrors app.js:1373's `state.template = data.config.defaultTemplate`
    /// at init, without clobbering a later selection on a later `adopt`.
    public func adopt(config: AppConfig) {
        agent = config.agent
        defaultTemplate = config.defaultTemplate
        if template.isEmpty {
            template = config.defaultTemplate
        }
    }

    /// `state.template || state.config.defaultTemplate` — used everywhere
    /// the JS reads `state.template` for the command/launch, never `template`
    /// directly, so an unset template still resolves to something runnable.
    public var effectiveTemplate: String {
        template.isEmpty ? defaultTemplate : template
    }

    /// `[defaultTemplate] + templates`, de-duplicated, first-seen order,
    /// empty entries dropped — ports populateTemplateSelect's `opts` (before
    /// the "Custom…" sentinel, which is the view's concern). Empty only when
    /// `defaultTemplate` is itself empty and `templates` is empty too — not
    /// reachable through normal app flow (`defaultConfig()` always seeds a
    /// real value), but a hand-edited `"defaultTemplate": ""` in
    /// sbx-helper.json survives `AppConfig`'s lenient decode unchanged, same
    /// as the Electron app's identical lack of validation on this field.
    public var templateOptions: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in [defaultTemplate] + templates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// Drives the custom-template field's visibility — derived rather than
    /// stored so it can't drift from `template`/`templateOptions`.
    public var usesCustomTemplate: Bool {
        !templateOptions.contains(effectiveTemplate)
    }

    public func loadTemplates() async {
        templates = await templateLister.listTemplates()
    }

    /// Ports the custom-template field's `change` handler (app.js:1338-1341):
    /// trims, falls back to `defaultTemplate` for a blank value, assigns,
    /// then persists. Persistence failures are swallowed — "the session
    /// still has the right value in memory" either way.
    public func commitTemplate(_ candidate: String) async {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        template = trimmed.isEmpty ? defaultTemplate : trimmed
        await persistTemplate(effectiveTemplate)
    }

    /// Paths currently marked editable, in JS-ordinal order (matching
    /// `buildArgs`/`resolvePrimary` — `JSOrder.precedes`, not Swift's
    /// canonical-equivalence `<`).
    public var editablePaths: [String] {
        selection.compactMap { $0.value == .editable ? $0.key : nil }.sorted(by: JSOrder.precedes)
    }

    /// Paths currently marked read-only, in JS-ordinal order. See
    /// `editablePaths`'s note on ordering.
    public var readOnlyPaths: [String] {
        selection.compactMap { $0.value == .readOnly ? $0.key : nil }.sorted(by: JSOrder.precedes)
    }

    public var resolvedPrimary: String? {
        resolvePrimary(editablePaths, explicit: primary)
    }

    public var manifest: [ManifestEntry] {
        manifestEntries(editable: editablePaths, readOnly: readOnlyPaths, primary: primary)
    }

    /// Ports app.js's refreshCommand — builds the same RunSelection the
    /// eventual launch uses, so the preview is always what will actually
    /// run.
    public var commandPreview: CommandPreview {
        let selection = RunSelection(
            agent: agent, template: effectiveTemplate, name: sandboxName, clone: clone,
            editable: editablePaths, readOnly: readOnlyPaths, primary: primary
        )
        do {
            let (_, display) = try buildCommand(selection)
            return .ready(display: display)
        } catch {
            return .unavailable(message: error.errorDescription ?? "")
        }
    }

    /// Derived rather than a stored `disabled` flag — this is what fixes the
    /// JS's Run-button-re-enables-with-an-empty-selection defect, since
    /// `isLaunching` (Task 8) is folded into the same derivation.
    public var canCopy: Bool {
        guard case .ready = commandPreview else { return false }
        return !isLaunching
    }

    public var canRun: Bool { canCopy }

    /// Ports app.js's doCopy (465-483). Does nothing when the preview isn't
    /// ready — mirrors the JS's `if (!text) return;`. `NSPasteboard`'s
    /// `setString` gives no reason on failure, so the error toast here
    /// deliberately doesn't try to interpolate one (a divergence from the
    /// JS's `Could not copy: ${err.message}`, which had a real message to
    /// show).
    public func copyCommand() {
        guard case .ready(let display) = commandPreview else { return }
        if clipboard.write(display) {
            toasts.show("Copied to clipboard.")
        } else {
            toasts.show("Could not copy: the clipboard rejected the text.", isError: true)
        }
    }

    /// Ports app.js's doRun (485-515) plus server.mjs's apiRun pre-launch
    /// validation. Order matters and matches both sources: the empty-
    /// selection pre-check (only reachable via ⌘↩, since the Run button is
    /// disabled in that state) comes first, then path validation, then argv
    /// assembly, then the actual launch.
    public func run() async {
        guard !editablePaths.isEmpty else {
            toasts.show("Select at least one editable folder first.", isError: true)
            return
        }

        let selection = RunSelection(
            agent: agent, template: effectiveTemplate, name: sandboxName, clone: clone,
            editable: editablePaths, readOnly: readOnlyPaths, primary: primary
        )
        do {
            try validateLaunchPaths(editablePaths + readOnlyPaths, exists: pathExists)
            let args = try buildArgs(selection)

            isLaunching = true
            defer { isLaunching = false }

            let result = await launcher.launch(args: args)
            if result.ok {
                toasts.show("Launched in a new terminal window.")
            } else {
                toasts.show(result.error ?? "Could not open a terminal window.", isError: true)
            }
            await persistTemplate(effectiveTemplate)
        } catch {
            toasts.show(error.errorDescription ?? "", isError: true)
        }
    }

    /// Ports app.js:121-136's `setSelection(path, kind)`. `kind == nil`
    /// deselects and, if `path` was the primary, clears `primary` — the
    /// only place a selection change clears it. A non-nil `kind` is first
    /// checked against `findCoveringPath` (excluding `path` itself, so
    /// converting an already-selected folder's kind in place is always
    /// legal); a covering conflict raises the overlap toast and leaves the
    /// selection untouched.
    public func setSelection(_ path: String, _ kind: SelectionKind?) {
        if let kind {
            let others = selection.keys.filter { $0 != path }.sorted(by: JSOrder.precedes)
            if findCoveringPath(path, in: others) != nil {
                toasts.show("Can't select that — it overlaps an existing selection.", isError: true)
                return
            }
            selection[path] = kind
        } else {
            selection.removeValue(forKey: path)
            if primary == path { primary = nil }
        }
        sortedSelectionKeys = selection.keys.sorted(by: JSOrder.precedes)
    }

    /// Ports the `e`/`r` keyboard shortcuts (app.js:1270-1283), which toggle
    /// rather than merely set: pressing the same kind twice clears it, and
    /// pressing the other kind converts. Mouse clicks (`setSelection`) are
    /// not toggles — this is deliberately a separate entry point.
    public func toggleSelection(_ path: String, _ kind: SelectionKind) {
        setSelection(path, selection[path] == kind ? nil : kind)
    }

    /// Ports the star button's click handler (app.js:302-338) — sets
    /// `primary` unconditionally, with no validation. `resolvedPrimary`
    /// applies the actual fallback rule.
    public func setPrimary(_ path: String) {
        primary = path
    }

    /// Ports app.js:615-634's confirm handler plus apiScan's persistence
    /// (server.mjs:155-175): validates the typed root, records it in the
    /// config (rootPath + recentRoots via `mutateConfig`, so `AppModel`
    /// stays the single owner), and kicks off the rescan — whose own
    /// root-change reset clears selection/primary/filter/expanded/cursor.
    /// Returns nil on success; on failure returns the message for the
    /// sheet's inline error (app.js's `rootError`), leaving all state
    /// untouched and raising no toast.
    public func changeRoot(to raw: String, maxDepth: Int, ignoreFolders: Set<String>) async -> String? {
        let resolved: String
        do {
            resolved = try resolveRoot(raw, exists: pathExists, isDirectory: pathIsDirectory)
        } catch {
            return error.errorDescription ?? ""
        }
        await mutateConfig {
            $0.rootPath = resolved
            $0.recentRoots = recordRecentRoot(resolved, in: $0.recentRoots)
        }
        scan(root: resolved, maxDepth: maxDepth, ignoreFolders: ignoreFolders)
        return nil
    }

    /// Ports app.js:646-676's confirm handler plus apiPresets' save branch.
    /// `existingPresets` comes from the caller (`AppModel.config.presets`) —
    /// the model never caches the preset list itself. Returns nil on
    /// success (with the saved/overwritten toast); on validation failure
    /// returns the message for the sheet's inline error (app.js's
    /// `saveError`), persisting nothing and raising no toast.
    public func savePreset(name: String, existingPresets: [Preset]) async -> String? {
        let preset: Preset
        do {
            preset = try buildPreset(
                name: name, rootPath: rootPath, template: template,
                defaultTemplate: defaultTemplate, sandboxName: sandboxName,
                clone: clone, editable: editablePaths, readOnly: readOnlyPaths
            )
        } catch {
            return error.errorDescription ?? ""
        }
        let (updated, overwritten) = upsertPreset(preset, into: existingPresets)
        await mutateConfig { $0.presets = updated }
        toasts.show(overwritten ? "Preset \"\(preset.name)\" overwritten." : "Preset \"\(preset.name)\" saved.")
        return nil
    }

    /// Ports app.js:725-764's loadPreset. Same-root loads apply
    /// immediately; a different root goes through `changeRoot`'s
    /// validate-persist-scan path with the selection stashed in
    /// `pendingPresetApply` for the winning scan task to consume. A root
    /// that no longer exists toasts (app.js has no inline error element on
    /// the presets dialog — it uses showToast) and changes nothing.
    /// Returns false in that failure case so the caller can keep the dialog
    /// open, matching the JS (which only closes on success).
    @discardableResult
    public func loadPreset(_ preset: Preset, maxDepth: Int, ignoreFolders: Set<String>) async -> Bool {
        if preset.rootPath != rootPath {
            let resolved: String
            do {
                resolved = try resolveRoot(preset.rootPath, exists: pathExists, isDirectory: pathIsDirectory)
            } catch {
                toasts.show(error.errorDescription ?? "", isError: true)
                return false
            }
            await mutateConfig {
                $0.rootPath = resolved
                $0.recentRoots = recordRecentRoot(resolved, in: $0.recentRoots)
            }
            pendingPresetApply = (preset, resolved)
            scan(root: resolved, maxDepth: maxDepth, ignoreFolders: ignoreFolders)
        } else {
            applyPresetSelection(preset)
        }
        toasts.show("Loaded preset \"\(preset.name)\".")
        return true
    }

    /// Ports app.js:766-775's deletePreset — filters by name through
    /// `mutateConfig` and toasts. No inline error path exists in the JS
    /// (failures surface as toasts), and filtering can't fail, so this
    /// returns nothing.
    public func deletePreset(name: String) async {
        await mutateConfig { $0.presets = SbxKit.deletePreset(named: name, from: $0.presets) }
        toasts.show("Deleted \"\(name)\".")
    }

    /// Ports app.js:191-197's revealInFinder: validates first (absolute,
    /// exists, is-a-directory — the same checks apiReveal applies), then
    /// opens the folder as its own Finder window. Success is silent, exactly
    /// like the JS; every failure toasts.
    public func reveal(_ path: String) {
        do {
            try validateRevealPath(path, exists: pathExists, isDirectory: pathIsDirectory)
        } catch {
            toasts.show(error.errorDescription ?? "", isError: true)
            return
        }
        if !revealer.reveal(path) {
            toasts.show("Could not open \(path) in Finder.", isError: true)
        }
    }

    /// Ports refreshCommand's `saveBtn.disabled` derivation (app.js:367,
    /// 381-383, 390): enabled exactly when the command builds. Unlike
    /// `canCopy`/`canRun`, an in-flight launch doesn't gate it — the JS
    /// never disabled Save while launching either.
    public var canSavePreset: Bool {
        guard case .ready = commandPreview else { return false }
        return true
    }

    /// Ports loadPreset's selection half (app.js:732-756): absolutizes the
    /// stored relative paths, replaces the whole selection, expands every
    /// ancestor so the restored folders are visible (app.js's
    /// `expandAncestors`), and restores template/name/clone with primary
    /// cleared. Filter text is deliberately *not* touched — same as the JS.
    private func applyPresetSelection(_ preset: Preset) {
        let (editable, readOnly) = absolutizePreset(preset)
        var next: [String: SelectionKind] = [:]
        for path in editable { next[path] = .editable }
        for path in readOnly { next[path] = .readOnly }
        selection = next
        sortedSelectionKeys = next.keys.sorted(by: JSOrder.precedes)
        for path in next.keys {
            for ancestor in tree.index.ancestors(of: path) {
                expanded.insert(ancestor)
            }
        }
        primary = nil
        template = preset.template
        sandboxName = preset.sandboxName ?? ""
        clone = preset.clone
        cursor = tree.nodes.first?.path
    }

    /// The selected path that makes `path` invalid to also select — nil for
    /// an already-selected path, since app.js only computes this for
    /// unselected rows (`covering = !sel ? findCoveringPath(...) : null`).
    public func coveringPath(for path: String) -> String? {
        guard selection[path] == nil else { return nil }
        return findCoveringPath(path, in: sortedSelectionKeys)
    }

    /// The user-visible "covered by X" reason, or nil when not covered.
    /// Ports app.js:265-270's exact text, including the root special case.
    public func coveredByLabel(for path: String) -> String? {
        guard let covering = coveringPath(for: path) else { return nil }
        if covering == tree.nodes.first?.path {
            return "covered by root"
        }
        let name = covering.split(separator: "/").last.map(String.init) ?? covering
        return "covered by \(name)"
    }

    /// Computed, not stored — `@Observable` has no `didSet`/`willSet` hook to
    /// recompute a cached value on. Observation tracks the stored reads
    /// inside (`tree`, `filterText`, `gitOnly`, `expanded`), so views
    /// invalidate correctly and `TextField`/`Toggle` get plain bindings.
    public var visibleRows: [TreeNode] {
        computeVisibleRows(
            nodes: tree.nodes, index: tree.index,
            filterText: filterText, gitOnly: gitOnly, expanded: expanded
        )
    }

    public func toggleExpanded(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
        }
    }

    /// Cancel-and-replace: `currentScanTask?.cancel()` below always runs
    /// before `scanGeneration` is bumped, so by the time any stale task
    /// resumes, `Task.isCancelled` is already true for it — that's what
    /// actually discards a stale result here, and it holds regardless of
    /// whether the scanner itself cooperates with cancellation (it's a flag
    /// on the `Task` handle, not something delegated to the callee). The
    /// `scanGeneration` comparison is kept alongside it as a self-contained
    /// invariant that doesn't depend on this method's cancel-then-launch
    /// ordering staying correct as it evolves — cheap defense-in-depth, not
    /// today's actual discriminator.
    public func scan(root: String, maxDepth: Int, ignoreFolders: Set<String>) {
        currentScanTask?.cancel()
        currentSpinnerTask?.cancel()

        scanGeneration &+= 1
        let generation = scanGeneration
        let delay = spinnerDelay
        // A rescan of the *same* root (⌘R, or a future auto-refresh) should
        // preserve what the user has expanded/selected; only an actual root
        // change resets to a fresh tree's defaults. Captured now, before any
        // task runs, so it reflects the root in effect at the moment this
        // particular scan() call was made.
        let isRootChange = root != rootPath

        let spinnerID = nextTaskID
        nextTaskID += 1
        let scanID = nextTaskID
        nextTaskID += 1

        let spinnerTask = Task { [weak self] in
            defer { self?.inFlightTasks.removeValue(forKey: spinnerID) }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if self.scanGeneration == generation {
                self.isScanning = true
            }
        }

        let scanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlightTasks.removeValue(forKey: scanID) }
            let result = await self.scanner.scan(root: root, maxDepth: maxDepth, ignoreFolders: ignoreFolders)
            guard !Task.isCancelled, self.scanGeneration == generation else { return }
            self.currentSpinnerTask?.cancel()
            self.tree = result
            self.rootPath = root
            if isRootChange {
                self.expanded = []
                self.cursor = result.nodes.first?.path
                // A root change discards the prior root's selection, primary
                // and filter — app.js:618-627's confirm handler does the
                // same for selection/primary; clearing filterText here too
                // fixes a Phase 3 review finding left unfixed (Electron does
                // clear it on root change).
                self.selection = [:]
                self.sortedSelectionKeys = []
                self.primary = nil
                self.filterText = ""
            } else if let cursor = self.cursor, !result.nodes.contains(where: { $0.path == cursor }) {
                // The previously-selected path no longer exists (e.g. the
                // folder was deleted since the last scan) — fall back
                // rather than pointing at nothing.
                self.cursor = result.nodes.first?.path
            }
            // A cross-root preset load stashed its selection before the
            // rescan (it had no tree to expand against yet) — apply it now
            // that the winning tree has landed. Consumed unconditionally so
            // a superseded scan can't leak it into a later, unrelated tree;
            // applied only when the roots match, so a manual root change
            // that landed first drops it instead.
            if let pending = self.pendingPresetApply {
                self.pendingPresetApply = nil
                if pending.root == root {
                    self.applyPresetSelection(pending.preset)
                }
            }
            self.isScanning = false
        }

        currentSpinnerTask = spinnerTask
        currentScanTask = scanTask
        inFlightTasks[spinnerID] = spinnerTask
        inFlightTasks[scanID] = scanTask
    }

    /// Awaits every scan/spinner task currently in flight, including stale
    /// ones a newer `scan()` call has already cancelled or superseded —
    /// each one removes itself from `inFlightTasks` on completion, so this
    /// is exactly the set still running. Test-only: no production caller
    /// needs deterministic settling, since nothing observes a scan's
    /// side effects synchronously the way a test does.
    public func quiesce() async {
        for task in inFlightTasks.values {
            await task.value
        }
    }

    /// Test-only visibility into whether `inFlightTasks` actually drains
    /// instead of growing without bound — see its declaration's doc comment.
    var inFlightTaskCountForTesting: Int { inFlightTasks.count }
}

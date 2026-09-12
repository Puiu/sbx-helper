import Foundation
import Observation
import SbxKit
import SbxServices

/// Sandboxes tab state: the sandbox list, selection, per-sandbox args
/// drafts, and the run/stop/remove actions driving them. Ports
/// src/electron/public/app.js's sandboxes tab (state 47-56, list/detail
/// 787-849/904-975, actions 1040-1123) plus server.mjs's apiSandboxRun
/// (persist-before-launch) and apiSandboxRemove (prune-stored-args) semantics.
///
/// Selection is the sandbox *name*, not the object — a refresh gives every
/// sandbox a new object identity, and the selected one may be gone entirely
/// (app.js:806-813's `applySandboxes`).
@MainActor
@Observable
public final class SandboxesModel {
    private let lister: SandboxListing
    private let controller: SandboxControlling
    private let policies: PolicyControlling
    private let launcher: TerminalLaunching
    private let toasts: ToastCenter
    private let mutateConfig: @Sendable (@escaping @Sendable (inout AppConfig) -> Void) async -> Void

    public private(set) var sandboxes: [Sandbox] = []
    public private(set) var sandboxesLoaded = false
    public private(set) var sandboxesError: String?
    public private(set) var selectedName: String?
    public private(set) var isBusy = false
    /// The selected sandbox's network policy rules — ports app.js's
    /// `state.policyRules`/`state.policiesFor`. Cleared on every real
    /// selection change (like the JS clearing before re-rendering) and
    /// (re)populated by `fetchPolicies()`.
    public private(set) var policyRules: [PolicyRule] = []
    /// Which sandbox name `policyRules` belongs to — ports
    /// `state.policiesFor`, including its "Loading…" contract: the rules
    /// belong to the selection only when this equals `selectedName`.
    public private(set) var policiesFor: String?
    public private(set) var isPolicyLoading = false
    /// A policy add/remove is in flight — gates only the policy controls
    /// (Add + remove buttons), never Run/Stop/Delete. The JS has no busy
    /// flag on the policy path at all; this one exists to prevent
    /// double-submits, which the JS is silently vulnerable to.
    public private(set) var isPolicyBusy = false
    /// The add-row's decision picker selection and free-text resource
    /// input — model-owned (not view `@State`) so the validation below is
    /// unit-testable, since SwiftUI-importing tests are forbidden.
    public var policyDecision: Decision = .allow
    public var policyInput: String = ""
    /// Inline add-row error — ports app.js's `#policyError`. Server-side
    /// add failures land here too (as in the JS); remove failures toast,
    /// also as in the JS.
    public private(set) var policyError: String?
    /// The last policy fetch failed — distinct from "no rules". The
    /// summary renders "Couldn't load policy rules." instead of counts so
    /// a failed load can't be mistaken for a genuinely rule-free sandbox
    /// once the failure toast fades.
    public private(set) var policyLoadFailed = false
    /// Discards stale policy fetches when the selection moves before an
    /// earlier fetch returns — the same generation pattern `BuilderModel`
    /// uses for scans.
    private var policyGeneration = 0
    /// Owned here (not the view) so a failed `confirmRemove` can leave the
    /// alert open — the native analogue of app.js's `deleteSandboxError`
    /// inline error, which likewise keeps the dialog up on failure.
    public var showsDeleteConfirm = false

    /// `config.sandboxArgs` snapshot — the stored display string per sandbox
    /// name. Seeded by `adopt(config:)` and kept in sync at this model's own
    /// `run()`/`confirmRemove()` mutation sites, the only two writers.
    private var storedSandboxArgs: [String: String] = [:]
    /// Session-only args-field drafts, one per sandbox name — app.js's
    /// `state.sandboxArgsText` Map. Never persisted directly; `run()`
    /// persists the normalized form.
    private var argsDrafts: [String: String] = [:]

    public init(
        lister: SandboxListing,
        controller: SandboxControlling,
        policies: PolicyControlling,
        launcher: TerminalLaunching,
        toasts: ToastCenter,
        mutateConfig: @escaping @Sendable (@escaping @Sendable (inout AppConfig) -> Void) async -> Void = { _ in }
    ) {
        self.lister = lister
        self.controller = controller
        self.policies = policies
        self.launcher = launcher
        self.toasts = toasts
        self.mutateConfig = mutateConfig
    }

    /// Takes `sandboxArgs` from the loaded config — mirrors
    /// `BuilderModel.adopt(config:)`'s role for the Builder tab's fields.
    public func adopt(config: AppConfig) {
        storedSandboxArgs = config.sandboxArgs
    }

    public var selectedSandbox: Sandbox? {
        guard let selectedName else { return nil }
        return sandboxes.first { $0.name == selectedName }
    }

    public var sandboxCountLabel: String {
        guard sandboxesLoaded else { return "" }
        return "\(sandboxes.count) sandbox\(sandboxes.count == 1 ? "" : "es")"
    }

    /// Ports app.js:806-813's `applySandboxes` folded into `fetchSandboxes`
    /// (815-827): stores the list, re-validates the selection against it,
    /// and records load state either way. A selected sandbox that vanished
    /// is deselected; its draft is dropped too, so a later sandbox recreated
    /// under the same name can't inherit stale text (the same reason
    /// server.mjs prunes `config.sandboxArgs` on remove).
    public func fetch() async {
        switch await lister.listSandboxes() {
        case .success(let list):
            sandboxes = list
            sandboxesError = nil
            if let selectedName, !list.contains(where: { $0.name == selectedName }) {
                self.selectedName = nil
                argsDrafts.removeValue(forKey: selectedName)
                clearPolicyState()
            }
        case .failure(let failure):
            sandboxes = []
            sandboxesError = message(for: failure)
            selectedName = nil
            clearPolicyState()
        }
        sandboxesLoaded = true
    }

    /// Ports app.js:843-849's `selectSandbox` — a no-op reselect stays one
    /// (the policy fetch Phase 7 adds keys off this being a real change).
    /// A real change also clears the policy display state immediately (the
    /// JS clears `state.policyRules` before re-rendering) and orphans any
    /// in-flight policy fetch via the generation bump.
    public func select(_ name: String) {
        if selectedName == name { return }
        selectedName = name
        clearPolicyState()
    }

    /// Resets the policy display state and orphans any in-flight policy
    /// fetch. Called on selection change, on selection loss, and at the
    /// start of every fetch.
    private func clearPolicyState() {
        policyGeneration += 1
        policyRules = []
        policiesFor = nil
        policyError = nil
        policyLoadFailed = false
        isPolicyLoading = false
    }

    /// Ports app.js:977-995's `renderPolicies` header contract: "Loading…"
    /// while the rules haven't caught up with the selection, the counts
    /// line once they have, nothing with no selection — and an honest
    /// unknown state after a failed load rather than "0 rules".
    public var policySummaryText: String {
        guard let selectedName else { return "" }
        if policiesFor == selectedName, !isPolicyLoading { return policySummary(policyRules) }
        return isPolicyLoading || !policyLoadFailed ? "Loading…" : "Couldn't load policy rules."
    }

    /// Ports app.js:829-841's `fetchPolicies`: clears the rules first,
    /// then stores what the (fresh, `requireKnownSandbox`-guarded)
    /// `listNetworkRules` returns. Stale results — from a fetch orphaned
    /// by a selection change mid-flight — are discarded via the
    /// generation. A failure toasts (like the JS) and marks the load
    /// failed, so the summary reports unknown instead of sticking on
    /// "Loading…" the way the JS does.
    public func fetchPolicies() async {
        guard let name = selectedName else { return }
        policyGeneration += 1
        let generation = policyGeneration
        policyRules = []
        policiesFor = nil
        policyError = nil
        policyLoadFailed = false
        isPolicyLoading = true
        defer { if policyGeneration == generation { isPolicyLoading = false } }
        switch await policies.listNetworkRules(name: name) {
        case .success(let rules):
            guard policyGeneration == generation, selectedName == name else { return }
            policyRules = rules
            policiesFor = name
        case .failure(let failure):
            guard policyGeneration == generation, selectedName == name else { return }
            policyLoadFailed = true
            toasts.show(message(for: failure), isError: true)
        }
    }

    /// Ports app.js:1125-1164's `doPolicyAdd`, including its client-side
    /// validation and its contract that failures (client- or server-side)
    /// surface inline in the add row, not as toasts. On success the
    /// returned re-listed rules replace the pane, the input clears, and a
    /// toast confirms — exactly like the JS.
    public func addPolicy() async {
        guard let name = selectedName else { return }
        // The Add button and the field's submit both stay live while busy —
        // the model is what actually prevents the double-submit.
        guard !isPolicyBusy else { return }
        let resources = parseResourceList(policyInput)
        if resources.isEmpty {
            policyError = "Enter at least one resource."
            return
        }
        if resources.count > maxResourcesPerRequest {
            policyError = "Too many resources at once (max \(maxResourcesPerRequest)) — split them into multiple additions."
            return
        }
        if let invalid = resources.first(where: { !isValidNetworkResource($0) }) {
            policyError = "Not a valid resource: \(invalid)"
            return
        }
        policyError = nil
        isPolicyBusy = true
        defer { isPolicyBusy = false }
        // Join the generation scheme: an add that completes while a fetch
        // is still in flight orphans that fetch (its data predates the
        // add), and a fetch started after the add orphans the add's own
        // result in favor of fresher data — either order converges.
        policyGeneration += 1
        let generation = policyGeneration
        switch await policies.addPolicy(name: name, decision: policyDecision, resources: resources) {
        case .success(let rules):
            // The rules belong to `name` — if the selection moved
            // mid-flight, applying them here would corrupt the new
            // selection's pane, so drop them (selecting back re-fetches).
            guard selectedName == name, policyGeneration == generation else { return }
            policyRules = rules
            policiesFor = name
            policyInput = ""
            toasts.show("Rule added.")
        case .failure(let failure):
            // Same staleness contract as success: A's failure must not
            // surface inline in B's pane after a mid-flight move.
            guard selectedName == name, policyGeneration == generation else { return }
            policyError = message(for: failure)
        }
    }

    /// Ports app.js:1166-1180's `doPolicyRemove`: the `SbxCLI` layer
    /// already re-validates `removable` against a fresh list before
    /// spawning, so the model just drives it and refreshes. Success
    /// re-lists (the removal returns `Void`, unlike the add path) and
    /// toasts; failure toasts — both exactly like the JS.
    public func removePolicy(_ rule: PolicyRule) async {
        guard let name = selectedName else { return }
        guard !isPolicyBusy else { return }
        isPolicyBusy = true
        defer { isPolicyBusy = false }
        switch await policies.removePolicy(name: name, ruleId: rule.id, resource: nil) {
        case .success:
            toasts.show("Rule removed.")
            // Refresh the sandbox that was acted on — if the selection
            // moved mid-remove, the new selection's own fetch owns its
            // pane, so don't clobber it.
            if selectedName == name { await fetchPolicies() }
        case .failure(let failure):
            toasts.show(message(for: failure), isError: true)
        }
    }

    /// Ports app.js:797-801's `defaultArgsTextFor`: the stored string when
    /// the config has one for this sandbox, else the per-agent default
    /// formatted for display.
    public func defaultArgsText(for sandbox: Sandbox) -> String {
        if let stored = storedSandboxArgs[sandbox.name] { return stored }
        return formatCommand(defaultAgentArgs(sandbox.agent))
    }

    /// The args field's current text: the typed draft when one exists, else
    /// the default. Pure (non-mutating) — unlike the JS, which seeds its Map
    /// as a render side effect; seeding here would write `@Observable` state
    /// from inside a view body evaluation.
    public func draftText(for sandbox: Sandbox) -> String {
        argsDrafts[sandbox.name] ?? defaultArgsText(for: sandbox)
    }

    public func setDraft(_ text: String, for name: String) {
        argsDrafts[name] = text
    }

    /// Ports app.js:952-975's `refreshSandboxCommand` — tokenizes the live
    /// field text through the same builder the launch uses, so the preview
    /// is always what will actually run.
    public var commandPreview: CommandPreview {
        guard let sandbox = selectedSandbox else {
            return .unavailable(message: "Select a sandbox to see details and actions.")
        }
        do {
            let args = try buildRunExistingArgs(name: sandbox.name, agentArgs: tokenizeArgs(draftText(for: sandbox)))
            return .ready(display: formatCommand(args))
        } catch {
            return .unavailable(message: error.errorDescription ?? "")
        }
    }

    public var canRun: Bool {
        guard case .ready = commandPreview else { return false }
        return !isBusy
    }

    /// Ports app.js:946's stop-button derivation — enabled only for a
    /// running sandbox, and never mid-operation.
    public var canStop: Bool {
        guard selectedSandbox?.status == "running" else { return false }
        return !isBusy
    }

    public var canDelete: Bool { selectedSandbox != nil && !isBusy }

    /// Ports app.js:1057-1086's `doSandboxRun` plus server.mjs:388-414's
    /// `apiSandboxRun`. Order matches the server: validate/build first (a
    /// 400 there is a toast here, persisting nothing), then persist the
    /// normalized args **before** launching — a launch failure (no terminal
    /// app, say) isn't a reason to discard what the user typed — then
    /// launch the argv `runExisting` built.
    public func run() async {
        guard let sandbox = selectedSandbox else { return }
        guard case .ready = commandPreview else {
            if case .unavailable(let message) = commandPreview {
                toasts.show(message, isError: true)
            }
            return
        }
        let tokens = tokenizeArgs(draftText(for: sandbox))

        isBusy = true
        defer { isBusy = false }

        let argv: [String]
        switch await controller.runExisting(name: sandbox.name, agentArgs: tokens) {
        case .failure(let failure):
            toasts.show(message(for: failure), isError: true)
            return
        case .success(let built):
            argv = built
        }

        // Mirrors the server exactly — the same tokenize-then-formatCommand
        // string, stored unconditionally once the args validated rather than
        // only after a successful launch. An empty tail deletes the key so a
        // later sandbox recreated under the same name starts clean.
        if tokens.isEmpty {
            await mutateConfig { $0.sandboxArgs.removeValue(forKey: sandbox.name) }
            storedSandboxArgs.removeValue(forKey: sandbox.name)
        } else {
            let display = formatCommand(tokens)
            await mutateConfig { $0.sandboxArgs[sandbox.name] = display }
            storedSandboxArgs[sandbox.name] = display
        }

        let result = await launcher.launch(args: argv)
        if result.ok {
            toasts.show("Launched in a new terminal window.")
        } else {
            toasts.show(result.error ?? "Could not open a terminal window.", isError: true)
        }
    }

    /// Ports app.js:1040-1055's `doSandboxStop` — toast, then re-fetch so
    /// the list shows the new status. No refresh on failure (matches the
    /// JS, whose `fetchSandboxes` sits inside the `try`).
    public func stop() async {
        guard let sandbox = selectedSandbox else { return }
        isBusy = true
        defer { isBusy = false }
        switch await controller.stop(name: sandbox.name) {
        case .success:
            toasts.show("Stopped \(sandbox.name).")
            await fetch()
        case .failure(let failure):
            toasts.show(message(for: failure), isError: true)
        }
    }

    public func requestDelete() {
        guard selectedSandbox != nil else { return }
        showsDeleteConfirm = true
    }

    public func cancelDelete() {
        showsDeleteConfirm = false
    }

    /// Ports app.js:1097-1117's `confirmDeleteSandbox` plus server.mjs's
    /// prune-on-remove (370-375): on success clears the selection and draft,
    /// prunes the stored args (otherwise a stale tail lingers and a later
    /// sandbox recreated under the same name silently inherits it),
    /// dismisses the alert, toasts, and re-fetches. On failure the alert
    /// stays open and the error toasts.
    public func confirmRemove() async {
        guard let sandbox = selectedSandbox else { return }
        isBusy = true
        defer { isBusy = false }
        switch await controller.remove(name: sandbox.name) {
        case .failure(let failure):
            toasts.show(message(for: failure), isError: true)
        case .success:
            await mutateConfig { $0.sandboxArgs.removeValue(forKey: sandbox.name) }
            storedSandboxArgs.removeValue(forKey: sandbox.name)
            argsDrafts.removeValue(forKey: sandbox.name)
            selectedName = nil
            clearPolicyState()
            showsDeleteConfirm = false
            toasts.show("Deleted \(sandbox.name).")
            await fetch()
        }
    }

    /// Renders an `SbxCLIFailure` the way the Electron routes' `{ error }`
    /// bodies surfaced to `showToast(err.message)` — the strings the detail
    /// pane's toasts show are these, not the case names.
    private func message(for failure: SbxCLIFailure) -> String {
        switch failure {
        case .toolNotFound:
            "sbx not found — set its location in Settings."
        case .infrastructure(let detail):
            detail.isEmpty ? "Could not list sandboxes." : detail
        case .unknownSandbox(let name):
            "Unknown sandbox: \(name)"
        case .ruleNotRemovable(let id):
            "That rule cannot be removed from here: \(id)"
        case .invalidResources:
            "One or more resources are invalid."
        case .invalid(let error):
            error.errorDescription ?? ""
        case .commandFailed(let detail):
            detail.isEmpty ? "The sbx command failed." : detail
        }
    }
}

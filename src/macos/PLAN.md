# Native macOS Swift rewrite of sbx-helper

## Status (2026-09-08)

**Phase 0 (toolchain spike) is complete — all 6 checkpoints pass.** See the [Phase 0 acceptance
checklist](#phase-0-acceptance-checklist--done-2026-09-08) for the full detail, including three
real findings baked into the tooling (`Scripts/test.sh`'s CLT-only flags, the async-process-off-
main-actor lesson, ad-hoc signing not surviving rebuilds for TCC purposes).

**Phase 1 (`SbxKit`) is complete — 164 tests green, zero UI code.** All modules from the table
below are ported and tested (`./Scripts/test.sh`), plus the release build and ad-hoc-signed `.app`
packaging both still succeed. Two corrections surfaced while reading the JS source closely enough
to port it, applied throughout this document:

- **`sandboxArgs` is `[String: String]`, not `[String: [String]]`.** `server.mjs:408` stores
  `formatCommand(agentArgs)` — a single quoted display string per sandbox name, put straight back
  into the text field on load — not an array of tokens.
- **`formatPort` actually lives in `public/shared/sandbox-commands.mjs`**, not `lib/sandboxes.mjs`
  (which only re-exports it). Ported to `Port.formatted` in `SbxModels.swift` either way.

Also decided during Phase 1: Swift names mirror the JS names (`quotePosix`, `findCoveringPath`,
`buildArgs`) rather than going fully Swift-idiomatic, so a diff against the JS stays easy to trace;
errors use Swift 6 typed throws over one `SbxKitError` enum; and the default `rootPath` is
`~/repos` if it exists, else `~`, since the JS's `process.cwd()` default only makes sense for a
shell-launched server (a GUI `.app`'s cwd is `/`).

**Phase 2 (`SbxServices`) is complete — 205 tests green (41 new), zero UI code beyond a throwaway
milestone probe.** All six files from the table below are implemented and tested
(`./Scripts/test.sh`); `swift build -c release` and `SIGNING_MODE=adhoc ./Scripts/package_app.sh
release` both still succeed. The milestone itself (`swift run SbxHelperApp` printing a parsed `sbx
ls`) was verified against the real `sbx` v0.39.0 — with a caveat: the app's own `.task` never fires
in a session with no attached display (no WindowServer session — see Phase 0's own "no attached
display" note), so the SwiftUI path was confirmed by direct code inspection plus a throwaway
non-UI check of `SbxCLI.listSandboxes()` against the real CLI, which matched `sbx ls --json`
exactly (3 sandboxes, names/agent/status byte-for-byte). A sighted run of the actual `.app` is
still the right final confirmation and is unchanged from the plan's own Verification section.

Two real findings surfaced while implementing `ProcessRunner`, both fixed and worth remembering:

- **`terminationHandler` firing does not imply the final `readabilityHandler` callback for a pipe
  has been delivered yet** — they're independent dispatch sources. Resolving as soon as
  termination fires (the design PLAN.md originally sketched) truncated a fast process's stdout
  (caught by `sbx ls --json`'s shim output, not by the emptier `stop`/`rm` cases that motivated the
  original design). Fixed by gating resolution on stdout EOF *and* stderr EOF *and* termination, a
  small `Coordination` class tracking all three.
- **Waiting for true pipe EOF can hang past `timeout` entirely if the child forks a grandchild that
  inherits the pipe and outlives the parent** — killing the tracked child doesn't close a
  grandchild's own copy of the write end. Fixed with a bounded (200ms) grace period after
  termination: if both EOFs haven't arrived by then, resolve anyway with whatever's been captured
  rather than block on a process we have no handle on. (Caught by a `Task`-cancellation test whose
  shim recipe happened to fork `sleep` as a genuine grandchild — a real hazard for any real child
  process tree, not just a test artifact.)

A fresh-eyes code review (`/feature-review`) then found 23 issues; 14 were fixed (219 tests green,
14 new): a **critical** gap where `removePolicy`'s by-resource path (as opposed to by-rule-id)
skipped the sandbox-scoped-and-editable re-validation entirely; `addPolicy` never validated
`resources` against SbxKit's `isValidNetworkResource`/`maxResourcesPerRequest`; a genuine SIGPIPE
crash writing stdin to a child that had already closed its read end (fixed with
`signal(SIGPIPE, SIG_IGN)` plus the throwing `write(contentsOf:)`, off the actor); a cap-truncated
UTF-8 buffer could get silently discarded entirely (switched to lossy `String(decoding:as:)`);
`ToolLocator`'s shell-probe result was cached without ever checking it actually existed on disk;
`TerminalLauncher` ignored `createFile`'s failure return; `addPolicy` was issuing two redundant
`sbx ls --json` calls; `ConfigStore` dropped `hadUnrecoverableFieldShape`; and several tests
(`SystemServicesTests` clobbering the real system clipboard, a debounce test that would pass even
with debouncing removed, a SIGKILL-escalation test that never checked the kill actually happened)
were verifying less than they claimed. The remaining 9 findings (loosely-toleranced test
assertions, minor coverage gaps, a couple of low-probability edge cases) were left for a future
pass — see the `/feature-review` output in session history for the full list.

**Phase 3 (App shell + Builder read-only) is complete — 250 tests green (31 new), first real UI.**
Two decisions departed from this document as written, both made with the user before implementing:

- **A fourth target, `SbxAppCore`,** holding the `@Observable` models (`AppModel`, `BuilderModel`)
  and a `ScanService` actor — imports `SbxKit`/`SbxServices`/`Observation` but never SwiftUI, so it
  links into a test target. Without it, the scan-generation/cancel-and-replace and spinner-race
  logic this phase introduces would have been covered by nothing but a manual checklist, since
  `SbxHelperApp` (the executable target) can't be linked into a test target under bare CLT and this
  document already forbids SwiftUI-importing tests (no ViewInspector, no XCUITest).
- **A `Rescan Folders` (⌘R) menu command,** added ahead of Phase 5's root picker so the async scan
  path — otherwise exercised exactly once per launch — is actually exercisable by hand. The Electron
  app has no Builder rescan at all; this is a native addition.

`DirectoryScanner`/`TreeIndex`/`computeVisibleRows`/`AppConfig`/`ConfigStore` (all ported in Phases
1–2) needed no changes — Phase 3 was view assembly plus the coordination layer driving them, not a
re-port.

A fresh-eyes code review then found 20 issues; 9 were fixed (250 tests green, 31 new total): a
**high-severity** bug where ⌘R's rescan-the-current-root path reused the root-*change* reset logic,
silently collapsing the user's expansion state and resetting the cursor on every manual refresh
(fixed by capturing `root != rootPath` at the top of `scan()` and only clearing `expanded`/`cursor`
on an actual root change, falling back the cursor only if its path no longer exists in the new
tree); the filter field's `"(press /)"` placeholder promised a keyboard shortcut that didn't exist
anywhere (fixed by lifting `@FocusState` from `TreeControlsView` up to `BuilderView` and adding
`.onKeyPress("/")` over the tree pane); `BuilderModel`'s scan-generation counter was proven
unreachable as a discriminator — `currentScanTask?.cancel()` always runs before the generation
bump, so `Task.isCancelled` is already true for any superseded task by the time it resumes,
regardless of whether the underlying scanner cooperates with cancellation — and the test claiming
to isolate generation-based discarding would still pass with the counter deleted (doc comments on
both corrected rather than deleting the counter, which stays as cheap defense-in-depth); the
`inFlightTasks` array grew without bound in production since only test-only `quiesce()` ever
drained it (fixed by switching to a keyed dictionary where each task removes itself via `defer` on
completion); a `StubScanner` design flaw where two `scan()` calls for the same root before either
released would silently drop the first continuation and hang `quiesce()` forever — now directly
relevant since ⌘R makes same-root rescans real (fixed by queueing continuations per root instead of
a single slot); a `ConfigBanner` message read "1 preset **were** dropped" (singular/plural verb
disagreement); `Package.swift`'s `SbxAppCoreTests` target used `SbxKit`/`SbxServices` without
declaring them as dependencies, compiling only via SwiftPM's transitive search path; and a doc
comment on `AppDelegate.onTerminate` named the wrong owner (`RootView` instead of
`SbxHelperApp.swift`'s `.task`). The remaining 11 findings (wall-clock-sensitive spinner tests, a
few dead-code/test-hygiene items, and several tentative low-probability edge cases — a `TempDirectory`
lifetime concern in one test, the root row's inert-but-clickable chevron matching an Electron quirk,
no dedicated empty/failed-scan UI state, `.task` re-running per window instance, `quiesce()` being
public production API for a test-only need, `ScanService`'s synchronous scan occupying a cooperative
thread, `filterText` surviving a scan unlike Electron, and a verbatim-duplicate `TempDirectory.swift`
between test targets) were left for a future pass.

This session has no attached display (same limitation as Phase 0/2's "no attached display" note),
so the sighted checklist in this document's own Verification section — tree rendering, filter/
git-only behavior, light/dark appearance, ⌘1/⌘2/⌘R — still needs a human to run
`./Scripts/compile_and_run.sh` and eyeball it. What *was* verified non-visually: the packaged
`.app` launches and stays alive (polled across several seconds, no crash-loop, no
`~/Library/Logs/DiagnosticReports` entries), registers as a foreground app, quits cleanly through
`applicationShouldTerminate`'s `.terminateLater` path, survives a deliberately malformed config file
without crashing, and round-trips `~/Library/Application Support/sbx-helper-swift/sbx-helper.json`
correctly on both launch and quit.

**Phase 4 (Builder interaction) is complete — 334 tests green (84 new).** The Builder tab now
builds and launches a real sandbox end to end: tri-state folder selection with the nested-mount
lockout, a manifest with a primary star, template/name/clone controls, a live command preview,
Copy, and Run in iTerm. Four decisions departed from this document as written, all made with the
user before implementing:

- **`Shared/ToastOverlay.swift` and `SbxAppCore/ToastCenter.swift` moved up from Phase 5 into
  Phase 4.** Three Phase 4 behaviors — Copy's confirmation, the overlap rejection's `Can't select
  that — it overlaps an existing selection.`, and Run's success/failure — had no other feedback
  channel, and the milestone ("launches a real sandbox") wasn't credible silently. Phase 5 inherits
  the overlay rather than building it.
- **Two Electron behaviors were fixed rather than ported.** `e`/`r` fire with any modifier in the
  JS (so `⌘E` toggles editable); the native version requires no modifiers
  (`BuilderView.handleToggle`). `doRun`'s `finally` re-enables the Run button unconditionally even
  with an empty selection; `canRun`/`canCopy` are derived from `commandPreview` and `isLaunching`
  instead of a stored flag, so that can't happen here.
- **`SbxCLI.listTemplates()` keeps its bare `[String]` return.** The picker always seeds
  `config.defaultTemplate` first and always offers "Custom…", so it never renders as empty — the
  "sbx not found" banner stays Phase 8's, as this document already assigned it.
- Also folded in while touching this code: a root change now clears `filterText` too (a Phase 3
  review finding left unfixed — Electron does clear it); `findCoveringPath` is fed a **sorted**
  path list rather than `Set` iteration order, so the `covered by X` label is deterministic when
  more than one selection overlaps.

New modules: `SbxKit/LaunchValidation.swift` (ports `server.mjs`'s `apiRun` pre-launch path
checks, since that Node server layer no longer exists) plus two new `SbxKitError` cases
(`.notAbsolutePath`, `.folderNotFound`); `SbxServices` gained the `TemplateListing` and
`ClipboardWriting` seams (deliberately narrower than this document's originally sketched
`SbxInvoking` — Phase 4 needs exactly one `SbxCLI` method); `SbxAppCore` gained `ToastCenter`,
`SelectionKind`, `ManifestEntry`, and `CommandPreview`, and `BuilderModel` grew from a scan
coordinator into the full Builder state machine (selection, primary, template/name/clone, the
command preview, copy, and run) with its init unchanged in earlier parameters but now taking
`templateLister`, `launcher`, `clipboard`, `persistTemplate`, and `pathExists`. `AppModel` gained
`update(_:)` — its first mutation path; `config` was previously `private(set)` with no writer at
all. `SbxHelperApp` gained `Shared/SegmentedTriStateView.swift`, replaced
`Builder/ManifestPlaceholderView.swift` with `ManifestView`/`ManifestRowView`/
`BuilderSettingsView`/`CommandPreviewView`, extended `FolderRowView` with the tri-state control,
the covered-by reason, and the permission tint (`Theme.write`/`Theme.read` and their `Bg`
variants — defined in Phase 3, used for the first time here), and extended `BuilderView`/
`AppCommands` with the arrow/`e`/`r` key handlers and a `Builder` command menu (`Run in iTerm` on
⌘↩, `Copy Command` with no shortcut). `SbxHelperApp.swift`'s `init()` now constructs the real
`ProcessRunner → ToolLocator → SbxCLI` graph plus `TerminalLauncher`, reading `config.sbxPath`
synchronously via `loadConfig` before `app.load()` has run, since `ToolLocator` needs it at
construction time.

Two things surfaced during implementation, not anticipated in the plan:

- **`TerminalLauncher.swift`'s `LaunchResult` had an `internal` memberwise initializer** — invisible
  from `SbxAppCoreTests`, which needed to construct stub results for `BuilderLaunchTests`. Fixed
  with an explicit `public init`, the same trivial fix Phase 2's `SystemServices` needed for a
  similar reason.
- **The `BuilderField` enum grew two cases beyond `BuilderView`'s own task boundary** —
  `.customTemplate` and `.sandboxName`, threaded through `ManifestView` and `BuilderSettingsView` as
  a shared `FocusState` binding, not just `BuilderView`'s tree pane. Without them, the tree's
  arrow/`e`/`r` handlers and the `/` filter-focus shortcut would have fired while the user was
  typing in the sandbox-name or custom-template field — the same `activeElement.tagName` guard
  `app.js`'s `onBuilderKeydown` relies on, which SwiftUI's focus system only replaces correctly if
  every text-entry site shares the one `FocusState`.

This session has no attached display (same limitation noted in every phase since Phase 0), so the
sighted checklist in this document's own Verification section — tri-state clicks, the covered-by
label and lockout toast, the primary star, template/name/clone, byte-for-byte command parity, Copy,
Run in iTerm actually opening a new iTerm window and starting a sandbox, ⌘↩ while typing, the
`⌘E`-does-nothing fix, light/dark permission-tint legibility, and full keyboard coverage — still
needs a human to run `./Scripts/compile_and_run.sh` and work through it. What *was* verified
non-visually: `swift build -c release` and `SIGNING_MODE=adhoc ./Scripts/package_app.sh release`
both succeed, and the packaged `.app` launches and stays alive (polled across several seconds, no
crash-loop, no `~/Library/Logs/DiagnosticReports` entries) — the same non-visual liveness check
every prior phase has used, since it's the only one available on this machine. A fresh-eyes
`/feature-review` is the next step before this phase is considered closed, following the same
review-and-fix pattern Phases 2 and 3 both went through (each caught one critical-or-high bug).

**Phase 5 (Builder dialogs) is complete — 391 tests green (57 new since Phase 4's 334),
Builder at parity.** Root picker, presets, save preset, and reveal are implemented and tested
(`./Scripts/test.sh`); `swift build -c release` and `SIGNING_MODE=adhoc
./Scripts/package_app.sh release` both succeed. It inherits `ToastOverlay` already built in
Phase 4, as planned. Three decisions departed from this document as written:

- **Sheets are `.sheet(isPresented:)` owned locally, not `.sheet(item:)` with a shared
  `BuilderSheet` enum.** Each button owns its sheet (root/presets in `BuilderToolbarSlotView`,
  save in `CommandPreviewView`); a sheet is a separate presentation whose keys never reach the
  tree's `.onKeyPress` handlers, so no shared enum is needed to coordinate them.
- **`BuilderField` gained no `.rootField`/`.presetName` cases** — the sheets own their focus
  with local `@FocusState` (documented in `BuilderView.swift`); the shared typing guard needs
  nothing new for the same separate-presentation reason.
- **No `.defaultAction` on the Change/Save buttons.** Enter already reaches `confirm()`/`save()`
  through `.onSubmit`, and a default button would fire it a second time (double scan + double
  config write; a double save reporting "overwritten" for a fresh preset).

New modules: `SbxKit/PresetStore.swift` (ports `server.mjs`'s `apiPresets` save/delete branches
plus `apiScan`'s root validation and recent-roots bookkeeping — that Node server layer no longer
exists, so the rules move here as pure functions); `validateRevealPath` extends
`LaunchValidation.swift` with `server.mjs`'s `apiReveal` checks (absolute + exists + is-directory);
`SbxServices` gained the `FinderRevealing` seam over `SystemServices.reveal` (NSWorkspace `open`,
silent on success, exactly like the JS); `BuilderModel` gained
`changeRoot`/`savePreset`/`loadPreset`/`deletePreset`/`reveal`/`canSavePreset` plus
`pendingPresetApply` — cross-root preset loads stash the preset for the winning scan task to
consume, since the rescan is async. Views gained `RootPickerSheet` (recent roots when empty, live
`PathCompleter` suggestions on a 120ms debounce, ↓/↑ clamp matching app.js, inline `rootError`,
trailing-slash accept), `PresetsSheet` (meta line, Load dismisses on success but stays open on a
missing-root toast, Delete stays open and re-renders, empty state), `SavePresetSheet` (autofocus,
inline `saveError`), the `root <path> [change] [presets]` toolbar slot, the `Save preset` button
gated on `canSavePreset` (mirroring `saveBtn.disabled`), and the `finder` button on each folder
row.

Coverage: `BuilderDialogsTests` (17 tests — changeRoot ×4, savePreset ×4 + canSavePreset,
loadPreset ×3 including rescan-then-apply and missing-root, deletePreset, reveal ×4),
`PresetRoundTripTests`, plus `PresetStoreTests` and `RevealValidationTests` for the new pure
logic. (The 57-new count also includes Phase 6's started `SandboxesModel` work — see below.)

This session has no attached display (same limitation as every phase since Phase 0), so the
sighted checklist — picker suggestions/highlight/Enter/Esc, preset save/load/delete including
cross-root and missing-root flows, reveal opening a Finder window, toasts — still needs a human
to run `./Scripts/compile_and_run.sh` and work through it. What *was* verified non-visually:
391 tests green, release build and ad-hoc packaging (plus `spctl --assess`) succeed, and the
packaged `.app` launches and stays alive as a foreground app (polled across six seconds, no
`~/Library/Logs/DiagnosticReports` entries), round-trips
`~/Library/Application Support/sbx-helper-swift/sbx-helper.json` with all keys intact, and quits
cleanly.

**Phase 5 closed (2026-09-11).** The fresh-eyes review happened as a full-tree
`/feature-review` rather than scoped to Phase 5 files, followed by a 5-fix wave
(all reviewed and verified, 399/399 tests green): malformed config preserved as
`.bak`; `ProcessRunner` cancellation now settles promptly even when the child
ignores SIGTERM; single `loadConfig` at launch with a refreshable `ToolLocator`
(success-only caching + `updateConfiguredPath`); JS-ordinal (`JSOrder`) ordering
for selection and manifest; `SbxKit` declared for `SbxServicesTests`. Tentative
findings were explicitly left out of scope.

**Phase 6 (Sandboxes tab) closed (2026-09-11).** `SandboxesModel` (list,
selection, per-sandbox args drafts + persistence, Run/Stop/Delete +
delete-confirm alert), the list/row/detail/toolbar views, and `SbxCLI`'s
mutating calls with `requireKnownSandbox` on every one — `SandboxesModelTests`
(21) and `SbxCLITests` (19) green, full suite 399/399.

**Phase 7 (Policies) is next.** Everything else from Phase 7 onward is still as originally
planned.

## Context

`src/electron/` holds a working local app for driving the `sbx` (Docker Sandboxes) CLI. It is a
Node `http` server plus a browser frontend, wrapped in Electron for the desktop build. It works,
but it pays for a browser engine and a loopback HTTP server it doesn't need: ~200MB of Electron,
a random per-launch bearer token, a `Host`-header DNS-rebinding guard, and a JSON API — all of
which exist purely because the UI happens to be a web page talking to a local server.

The goal is a native macOS SwiftUI app at `src/macos/` with full feature parity. Going native
deletes the entire network surface (no socket, no token, no CORS/rebinding concerns — the trust
boundary becomes the local user, who already has a shell), replaces two subprocess shell-outs
with native APIs (`pbcopy` → `NSPasteboard`, `open <dir>` → `NSWorkspace`), and cuts the install
from ~200MB to a few MB.

This phase produces the plan and installs the Swift skills. Implementation follows in phases 0–8.

### Decisions made with the user

| Decision | Choice |
|---|---|
| Build toolchain | **SPM only, no Xcode** — `Package.swift` + `swift build`, `.app` assembled by a script |
| Scope | **Full parity**, delivered in ordered phases |
| Config file | **Own file, same schema** — `~/Library/Application Support/sbx-helper-swift/sbx-helper.json` |
| Skills | swiftui-pro, macos-spm-app-packaging, swift-concurrency, swift-testing-pro, macos-design-guidelines |

### Verified toolchain constraints

These were checked on this machine, not assumed:

- `xcode-select -p` → `/Library/Developer/CommandLineTools`. **Xcode is not installed.**
- Swift 6.3.3, default target `arm64-apple-macosx26.0`. SDKs: `MacOSX26.5` (default), 15.4, 15.
- `SwiftUI`, `SwiftUICore`, `AppKit`, `UniformTypeIdentifiers` are **present** in the CLT SDK.
  `Observation` resolves as a toolchain module, so `@Observable` works.
- A probe of `@main App` + `@NSApplicationDelegateAdaptor` + `@Observable` + `.commands`
  typechecked clean under `-swift-version 6 -strict-concurrency=complete`.
- **swift-testing is bundled in CLT** (`.../Library/Developer/Frameworks/Testing.framework`).
  **XCTest is absent.** → use `import Testing`, and add **no package dependencies**.
- `actool` is **absent** → no asset catalogs, ever. Colors live in Swift; the icon is an `.icns`
  built by `iconutil` and checked in.
- `codesign`, `iconutil`, `plutil` are present. `sbx` is at `/opt/homebrew/bin/sbx` (v0.39.0).

---

## Step 0 — Install the Swift skills (project-only) — ✅ DONE

Installed and confirmed in `.claude/skills/` (project-scoped, not global).

```console
$ npx -y skills add twostraws/swiftui-agent-skill --skill swiftui-pro -y
$ npx -y skills add dimillian/skills --skill macos-spm-app-packaging -y
$ npx -y skills add avdlee/swift-concurrency-agent-skill --skill swift-concurrency -y
$ npx -y skills add twostraws/swift-testing-agent-skill --skill swift-testing-pro -y
$ npx -y skills add ehmo/platform-design-skills --skill macos-design-guidelines -y
```

`dimillian/skills` and `ehmo/platform-design-skills` are multi-skill repos (16 and 8 skills) —
`--skill` is what keeps the install to the one we want. All five repo paths were verified to
resolve. Confirm with `npx skills ls` and by checking `.claude/skills/`.

`macos-spm-app-packaging` is the load-bearing one: it covers exactly the no-Xcode
SPM-to-`.app` path this project is forced onto.

---

## Target layout

Where this ends up (Phase 8):

```
src/macos/
  Package.swift              swift-tools 6.2, platforms: [.macOS(.v14)], ZERO dependencies
  Sources/
    SbxKit/                  library — pure logic, models, FS scan, config codec (Foundation only)
    SbxServices/             library — Process, sbx CLI, terminal launch, tool location
    SbxHelperApp/            executable — SwiftUI only
  Tests/
    SbxKitTests/
    SbxServicesTests/Fixtures/sbx-shim.sh
  Scripts/
    test.sh                   swift test, with the CLT-only swift-testing flags — see Phase 0
    package_app.sh             build + assemble + sign the .app (skill template, customized)
    compile_and_run.sh         dev loop: kill running copy, package, relaunch, verify
    install.sh                 Phase 8: port of bundle-and-install.sh — install to /Applications
    setup_dev_signing.sh       Phase 1: stable local signing identity so TCC grants survive rebuilds
  version.env, .gitignore
  README.md, CLAUDE.md
```

**Current state (end of Phase 0):** `Package.swift`, `Scripts/{test,package_app,compile_and_run}.sh`,
`version.env`, `.gitignore` exist and work. `Sources/SbxKit/Spike.swift`,
`Tests/SbxKitTests/SpikeTests.swift`, and `Sources/SbxHelperApp/{SbxHelperApp,PhaseZeroProbes}.swift`
are the throwaway Phase 0 spike — real modules replace them starting Phase 1.
`Sources/SbxServices/`, `Scripts/install.sh`, `Scripts/setup_dev_signing.sh`, `README.md`, and
`CLAUDE.md` don't exist yet.

**The three-target split is not hygiene, it's necessity.** SwiftPM on macOS cannot cleanly link
an `@main` executable target into a test target — you fight `-parse-as-library` and duplicate
`main` symbols, and without Xcode there is no fallback. Isolating the logic in `SbxKit` is the
only low-friction way to get `swift test` working at all. It also happens to be where ~130 of the
existing 149 tests already live conceptually.

---

## SbxKit — pure logic, ported 1:1

Everything `Sendable`, `nonisolated`, no `Process`, no AppKit, no SwiftUI.

| New file | Ports from |
|---|---|
| `Quoting.swift` | `command.mjs` — `quotePosix`, `formatCommand` |
| `RunCommand.swift` | `command.mjs` — `orderedWorkspaces`, `buildArgs`, `buildCommand` |
| `Selection.swift` | `selection.mjs` — `isAncestor`, `findCoveringPath`, `findAnyConflict`, `resolvePrimary` |
| `AgentArgs.swift` | `sandbox-commands.mjs` — `AGENT_DEFAULT_ARGS`, `tokenizeArgs`, `validateAgentArgs`, limits |
| `SandboxCommands.swift` | `sandbox-commands.mjs` — `buildRunExistingArgs`, `buildStopArgs`, `buildRemoveArgs`, `buildPolicyAddArgs`, `buildPolicyRemoveArgs` |
| `NetworkResource.swift` | `sandbox-commands.mjs` — `isValidNetworkResource`, `parseResourceList`, `MAX_RESOURCES_PER_REQUEST` |
| `SbxModels.swift` | `lib/sandboxes.mjs` (+ `formatPort` from `sandbox-commands.mjs`, which is its real source — `lib/sandboxes.mjs` only re-exports it) — `Sandbox`, `Port`+`formatPort`, `PolicyRule` + `sandboxScoped`/`removable` classification |
| `TemplateList.swift` | `lib/templates.mjs` — `parseTemplateLs` |
| `DirectoryScanner.swift`, `TreeNode.swift`, `PathCompleter.swift` | `lib/scan.mjs` |
| `TreeIndex.swift`, `VisibleRows.swift` | lifted out of `public/app.js` — `indexTree`, `computeHasGitDescendant`, `computeVisibleRows` |
| `AppConfig.swift`, `Preset.swift`, `ConfigCodec.swift`, `RelativePath.swift` | `lib/config.mjs` |

Pulling `indexTree` / `computeVisibleRows` down into `SbxKit` is what keeps the SwiftUI views
thin and testable — do not let that filter/expansion logic live in a `View`.

### Directory scanning — the parity traps

`FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)` with explicit
recursion (not `enumerator` — you need per-directory depth capping, ignore-list pruning and
`unreadable` marking, which `skipDescendants` makes awkward). Each of these becomes a `@Test`:

1. Flat, depth-first **pre-order**; root at index 0 with `depth == 0` and `name == the full path`
   (`app.js` relies on that special case).
2. Root always emitted, even when unreadable. Throw → `unreadable = true`, emit, don't recurse.
3. `isGitRepo` = plain `fileExists(atPath: dir + "/.git")` — **not** an is-directory check. Node's
   `existsSync` matches a `.git` *file*, which is what worktrees and submodules produce, and this
   app is used heavily with `sbx run --clone` worktrees.
4. **Skip symlinks.** Node's `Dirent.isDirectory()` is `lstat`-based, so a symlink-to-directory is
   *not* a directory and is skipped. `URL.isDirectoryKey` resolves the link and would include it —
   a behavior change plus a cycle hazard. Fetch `.isSymbolicLinkKey` and skip.
5. Do the dot-prefix filter **manually**; do not pass `.skipsHiddenFiles`, which also honors the
   hidden *flag* that `name.startsWith('.')` does not.
6. Sort with `localizedStandardCompare` (Finder-like, numeric-aware). This diverges from Node's
   `localeCompare` on `repo2` vs `repo10` — intentional, better, and worth a comment.

### Config — where a naive Codable port regresses

`config.mjs` does `{...defaultConfig(), ...parsed}` **and then** `coerceTypes()`, so
`"presets": null` falls back to the default instead of crashing. `decodeIfPresent` **throws** on a
type mismatch — it does not return nil — so a straight `Codable` conformance turns one wrong-typed
field into a total decode failure and **loses every preset**. Write a custom `init(from:)` with:

```
func lenient<T: Decodable>(_ key: CodingKeys, default: T) -> T
    = (try? container.decodeIfPresent(T.self, forKey: key)) ?? `default`
```

applied to every field. The existing `config.test.mjs` coercion tests then port directly.

- **Location:** `~/Library/Application Support/sbx-helper-swift/sbx-helper.json`. Deliberately
  *not* the Electron app's `sbx-helper/` directory — the schema is identical so presets can be
  copied over by hand, but the two apps can't clobber each other while both exist. Keep the
  `SBX_HELPER_CONFIG` env override for tests and dev.
- Keep `port` in the model even though nothing reads it, so round-tripping a copied-over file
  doesn't silently drop fields.
- Add one new optional field: `sbxPath` (see ToolLocator below).
- **Atomic write:** `data.write(to:options:[.atomic])` does the same-directory temp + `rename(2)`
  that `saveConfig` hand-rolls, so that machinery and its "no leftover temp file" test disappear.
- Malformed JSON → defaults + a non-fatal `configError` banner, as today. Improvement: rename the
  bad file to `.bak` before the next write so a hand-editing slip doesn't destroy presets.
- `RelativePath.swift` is a genuine reimplementation (Swift has no `path.relative()`). Must return
  `""` for equal paths, because `app.js`'s `joinPath` special-cases `""` and `"."` back to root.
  Round-trip test it.

---

## SbxServices

| File | Purpose |
|---|---|
| `ProcessRunner.swift` | `actor` — the `node:child_process.spawn` replacement |
| `ToolLocator.swift` | resolve absolute `sbx` path + child `PATH` |
| `SbxCLI.swift` | `listSandboxes`, `listTemplates`, `listNetworkRules`, `stop`, `remove`, `policyAdd/Remove` |
| `TerminalLauncher.swift` | temp `.command` + `osascript`, ported from `lib/terminal.mjs` |
| `SystemServices.swift` | `NSPasteboard` copy, `NSWorkspace` reveal — the only AppKit import here |
| `ConfigStore.swift` | load/save/debounce |

Seams for testing: `protocol CommandRunning`, `SbxInvoking`, `TerminalLaunching` (all `Sendable`).
These replace the Node `startServer({ launcher })` module-level mutable injection with something
narrower and compiler-checked.

### ProcessRunner — five real traps

`func run(executable:arguments:stdin:environment:timeout:maxOutputBytes:) async -> CommandResult`,
returning a `Sendable` struct and **never throwing** (mirrors the Node contract; right for a UI
that must always render something).

1. **Drain both pipes concurrently.** `Pipe`'s buffer is ~64KB; `waitUntilExit()`-then-read
   deadlocks the moment `sbx` prints more. Install `readabilityHandler` on both before `run()`.
2. **Keep draining after the output cap** and discard. Stopping the read re-creates the deadlock —
   the Node `append()` helper does exactly this. Add a test, because it's easy to "optimize" away.
3. **Sendable escape hatch.** `Process`/`Pipe`/`FileHandle` are non-`Sendable` and
   `readabilityHandler` fires on an arbitrary queue. Use one
   `final class OutputBuffer: @unchecked Sendable` per stream guarded by `NSLock`; keep the
   `Process` confined to the actor. Anything cleverer fights the compiler for no gain.
4. **Exactly-once resume.** `withCheckedContinuation` + `terminationHandler`, guarded by a
   lock-protected `settled` flag. Node's `finish()` guard exists for this reason; in Swift the
   consequence of getting it wrong is a crash, not a dropped promise.
5. **Timeout as a race, not a timer.** `withTaskGroup` racing termination against
   `Task.sleep`. On timeout: `process.terminate()` (SIGTERM), then a detached task that sleeps 2s
   and calls `kill(pid, SIGKILL)` from Darwin — `Process` has no SIGKILL API. Capture
   `processIdentifier` first. Return `.timedOut` immediately without waiting. Direct port of
   `runSbx`'s two-stage kill, including "give up waiting but still don't leave it running".

Plus `withTaskCancellationHandler` so a cancelled caller Task terminates the child.

### ToolLocator — the biggest behavioral break from Electron

A GUI-launched `.app` gets launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`); `/opt/homebrew/bin`
is **not** on it. And Foundation's `Process` does **no** PATH search — `executableURL` must be
absolute. Resolve once at launch, cache in an actor:

1. `SBX_HELPER_SBX_PATH` env var (tests, dev)
2. `sbxPath` from config (set via a Settings sheet)
3. probe `/opt/homebrew/bin/sbx`, `/usr/local/bin/sbx`, `~/.local/bin/sbx`, `/usr/bin/sbx`
4. `/bin/zsh -lc 'command -v sbx'` (2s timeout) — picks up asdf/mise/nix shims
5. failure → persistent banner "sbx not found — set its location in Settings". **Do not** silently
   degrade to an empty template list the way `listTemplates` does today; in a GUI that reads as
   "you have no templates", which sends the user looking in the wrong place.

Also set the child environment explicitly on every `sbx` call: inherit the process environment,
then prepend the resolved directory plus `/opt/homebrew/bin:/usr/local/bin` to `PATH` — `sbx`
shells out to `docker` itself, which lives in the same prefix. *The packaged Electron app has this
latent bug too; fix it here.* The temp `.command` script is unaffected (it runs under the user's
interactive login shell inside iTerm), so keep emitting bare `sbx` in the preview and the script.

### TerminalLauncher — carry over verbatim

`lib/terminal.mjs`'s decision to avoid stacked AppleScript-over-shell escaping by making the only
interpolated value a path the app generated itself is the best call in that file. Port it exactly:
`mkdtemp` (0700) → write `run.command` `#!/bin/sh\nexec <formatCommand(args)>\n` (0700) →
`osascript -e` → fall back to `open -a iTerm`, then `open -a Terminal`. Keep
`escapeAppleScriptString` even though the input is app-generated.

One fix: the current code leaks a temp dir per run, forever. Add a best-effort launch-time sweep of
`sbx-helper-*` dirs in `NSTemporaryDirectory()` older than 24h. Immediate deletion is not possible
— iTerm sources the script asynchronously.

---

## App target — SwiftUI

```
Sources/SbxHelperApp/
  SbxHelperApp.swift        @main App, WindowGroup, .commands, @NSApplicationDelegateAdaptor
  AppDelegate.swift         activation policy, terminate-on-last-window, config flush
  RootView.swift            toolbar tab picker + switch(activeTab)
  Theme.swift               palette ported from public/styles.css
  Builder/                  BuilderView, FolderTreeView, FolderRowView, ManifestView,
                            BuilderSettingsView, CommandPreviewView,
                            RootPickerSheet, PresetsSheet, SavePresetSheet
  Sandboxes/                SandboxesView, SandboxRowView, SandboxDetailView, PolicyListView
  Shared/                   ToastOverlay, SegmentedTriState, ErrorBanner
```

### State model

`@Observable`, not `ObservableObject` — verified working under CLT, and per-property invalidation
matters here: with `ObservableObject` every keystroke in the filter field would invalidate the
manifest pane, command preview and whole tree. Requires macOS 14 (`platforms: [.macOS(.v14)]`,
`LSMinimumSystemVersion = 14.0`).

- `@MainActor @Observable final class AppModel` — config, active tab, toast, sbx availability
- `@MainActor @Observable final class BuilderModel` — tree, selection, filter, cursor, template/name/clone
- `@MainActor @Observable final class SandboxesModel` — list, selection, args drafts, policy rules, busy

Created as `@State` in the App, injected via `.environment(...)`. `ProcessRunner`, `SbxCLI`,
`ScanService`, `ConfigWriter` are **actors** — models `await` them, and the compiler enforces that
only `Sendable` values cross.

**Where the scan runs:** `actor ScanService`, not `Task.detached` — an actor serializes for free,
which matters because two rapid root changes must not interleave and the second must win. Hold a
`scanGeneration: Int` on the model and discard stale results. Race a 150ms `Task.sleep` to decide
whether to show a `ProgressView` (local scans are 15–50ms so it normally never appears — but a
`~/Documents` scan behind a TCC prompt, or an SMB mount, will block for seconds).

Filtering / `gitOnly` / expansion stays **synchronous on the main actor** over the in-memory flat
array — O(n) over a few hundred nodes; going async would add latency to every keystroke.

Every `clearTimeout` becomes a cancellable `Task` stored on the model: 120ms autocomplete
debounce, 3.5s toast dismissal, cancel-and-replace for in-flight `sbx` calls.

### The tree list — use `List`, and here's why

**`List` over the flattened `visibleRows: [TreeNode]`, `selection:` bound to the cursor,
`.listStyle(.plain)`, `.onKeyPress` for custom keys.**

- It matches the existing architecture: `computeVisibleRows` already flattens filter + gitOnly +
  expansion + auto-expand-while-searching into one array. `OutlineGroup`/`DisclosureGroup` would
  fight all four.
- `List(selection:)` gives **built-in `↑`/`↓` navigation with scroll-into-view** plus row recycling
  with stable identity. Reimplementing that over `LazyVStack` is guaranteed to be worse.
- `NSViewRepresentable` + `NSTableView` is the right answer at 10k+ rows, but these trees are 316
  nodes at depth 3 / 677 at depth 4 (measured, per the `scan.mjs` comment). **Document it in
  CLAUDE.md as the escape hatch**: `FolderTreeView` is the one file to swap out if row counts ever
  exceed ~5k — nothing else depends on its internals.

| Key | Mechanism |
|---|---|
| `↑` `↓` | free from `List(selection:)` |
| `←` `→` | `.onKeyPress(.leftArrow/.rightArrow)` → toggle `expanded` |
| `e` `r` | `.onKeyPress(characters:)` |
| `/` | `.onKeyPress` guarded by `@FocusState` — the analogue of the JS `typing` guard |
| `⌘↵` | `.commands { CommandMenu }` — focus-independent, and populates the menu bar |
| `⌘1` `⌘2` | `.commands`, View menu — **replaces** the ARIA `←`/`→`-on-tab-button idiom (native convention) |

`@FocusState` enum `.filter, .tree, .sandboxArgs, .rootField, .presetName` — one per text-entry
site.

### Layout, dialogs, theme

- **`HSplitView`, not `NavigationSplitView`** — the two panes are peers (tree ↔ manifest), not
  sidebar/detail. `NavigationSplitView` imposes chrome you'd spend time suppressing.
- **Not `TabView`** — on macOS it renders boxed chrome that doesn't match, and doesn't support the
  per-tab toolbar slots (root path/change/presets vs count/refresh). Use a segmented `Picker` in
  `.toolbar` with content switching on the active tab.
- Root picker / presets / save preset → `.sheet(item:)` with an `enum BuilderSheet: Identifiable`.
- Delete sandbox → **`.alert`**, not a sheet: it's a confirmation and gets Esc/`⌘.` and
  Return-to-default for free.
- Toast → `.overlay(alignment: .bottom)` + `AccessibilityNotification.Announcement` to replace
  `role="status"`.
- **Theme:** port `public/styles.css`'s custom properties directly. The semantics — *deep amber =
  the agent can write here, steel blue = read-only, everything path-shaped is monospace* — are the
  app's best design decision and must survive. Since `actool` is absent, define them as
  `Color(nsColor: NSColor(name:nil) { ... })` so they follow appearance changes without an asset
  catalog. Consult the `macos-design-guidelines` skill for HIG conformance.

---

## Bundling — `Scripts/bundle.sh` (ports `bundle-and-install.sh`)

`swift build -c release` → `--show-bin-path` → assemble `dist/sbx-helper.app/Contents/{MacOS,Resources}`
→ `Info.plist` → **sign last**.

Info.plist keys that matter:

- `CFBundleIdentifier` — **must be stable forever**; TCC grants are keyed to it.
- `NSPrincipalClass = NSApplication`, `NSHighResolutionCapable = true`, `LSMinimumSystemVersion = 14.0`
- `NSAppleEventsUsageDescription` — **required**. Since 10.14 an AppleEvent without it is denied
  (`errAEEventNotPermitted`, -1743). *"sbx-helper opens a new iTerm2 window to run the sbx command
  you assembled."*
- `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
  `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription` — the app is
  non-sandboxed but macOS still gates these; Electron supplied them implicitly and a hand-rolled
  bundle must declare them. A denial makes `contentsOfDirectory` throw, which the existing
  `unreadable` model already handles.

Signing:

- **Ad-hoc codesign is not optional.** `codesign --force --sign - --identifier <bundle-id>` —
  TCC keys the Automation grant to the code-signing identity, so an unsigned bundle re-prompts on
  every rebuild or silently denies. Separately, on Apple Silicon a bundle needs at least an ad-hoc
  signature to launch. Editing `Info.plist` after signing invalidates it → sign last.
- **Do not** enable the hardened runtime with ad-hoc signing — restrictions, no benefit.
- **Do not** sandbox. No entitlements file at all. With App Sandbox you'd also need
  `com.apple.security.automation.apple-events` plus security-scoped bookmarks for every scanned
  root. Not worth it for a personal dev tool.
- README should carry `tccutil reset AppleEvents <bundle-id>` for when TCC state goes stale.

`Scripts/install.sh` ports the rest of `bundle-and-install.sh` 1:1 — quit any running copy,
replace `/Applications/sbx-helper.app`, `xattr -cr`, relaunch. Idempotent.

---

## What disappears, and what must survive

### Deleted

The `node:http` server (routing, static serving, MIME map, path-traversal guard, `readJson`'s 2MB
cap and UTF-8 chunk-boundary handling, EADDRINUSE port fallback); the random bearer token
(`randomBytes`, `timingSafeEqual`, the byte-length guard, `?t=`, `sessionStorage`,
`history.replaceState` scrubbing); the `Host` check and DNS-rebinding defense; `apiFetch` and all
14 route handlers; the `pbcopy` and `open <dir>` subprocesses; the module-level `launcher`
injection seam; `test/server-sandboxes.test.mjs` (its argv assertions move down into
`SbxServicesTests` against the shim, where they belonged).

**The security model collapses to "no network surface at all."** No socket, no IPC, no XPC, no URL
scheme. Every capability the app exposes is something the user could already type in a shell.

### Survives — but the *reason* changes, so rewrite the doc comments

1. **`validateAgentArgs`** (≤32 tokens, ≤256 chars, no control chars) — keep the rules and tests.
   The justification is no longer "untrusted client input"; it's **display integrity and blast
   radius**: a newline inside a token makes the monospaced preview *lie* about what will run, and
   the caps stop a paste accident from generating a multi-megabyte `.command` file. Say that
   explicitly, or someone deletes it as vestigial.
2. **`quotePosix` / `formatCommand`** — *more* load-bearing than before. The output lands in a real
   `#!/bin/sh` script the user's shell executes; a quoting bug is live shell injection into their
   own terminal. Keep `SAFE_UNQUOTED` and the `'\''` idiom byte-for-byte, and keep the
   `tokenizeArgs` ↔ `quotePosix` round-trip tests — that round-trip is what makes the preview truthful.
3. **`findAnyConflict`** — keep as a precondition inside `buildArgs`. Presets loaded from a
   hand-edited config still bypass the UI's per-click `findCoveringPath` check.
4. **Absolute-path + existence checks before launching** — a preset can reference a folder deleted
   since it was saved; "Folder not found: X" beats `sbx` failing cryptically.
5. **`requireKnownSandbox` on every mutating call, never cached** — the reasoning is unchanged and
   still sharp: **`sbx policy ls <bogus-name> --json` exits 0 and returns the *global* rules.**
   Without it the policy pane renders global policy while claiming to show a sandbox's. Arguably
   *more* important in a GUI, where the list can go stale between render and click.
6. **`removable` re-validation before `policy rm`** — re-list, find the target, refuse anything not
   sandbox-scoped-and-editable. `--sandbox <name>` must **never** be omitted; omitting it silently
   targets global policy.
7. **Fail-closed `editable == true`** in rule parsing — a rule missing the field is not editable.
8. **Process timeouts, output caps, SIGTERM→SIGKILL** — a wedged `sbx` must not hang the UI.

### New validation surfaces introduced by going native

`sbx` location (Electron got PATH free from the launching shell); TCC Automation for the iTerm
AppleEvent; TCC folder access for scanning `~/Desktop`/`~/Documents`/`~/Downloads`; bundle-identity
stability.

---

## Testing

`import Testing` (swift-testing), **no package dependency** — it's in the toolchain, and depending
on the `swift-testing` package would duplicate/conflict. XCTest is not installable under CLT.

- `SbxKitTests` — port ~130 of the existing 149 tests. `@Test(arguments:)` maps beautifully onto
  the large case tables in `tokenizeArgs`, `isValidNetworkResource` and `quotePosix`.
- `SbxServicesTests` — real `ProcessRunner` against `Tests/SbxServicesTests/Fixtures/sbx-shim.sh`
  (port of `test-fixtures/sbx-shim.js`): JSON parse paths, non-zero exit, timeout + kill
  escalation, output-cap behavior, stdin.
- **Write no tests that import SwiftUI.** They'd link fine but there's nothing to assert on — no
  ViewInspector (external dep), no XCUITest (needs Xcode). Any such test is a compile check
  masquerading as a test. All view logic worth testing lives in `SbxKit` as pure functions.
- Run with `swift test`; fall back to `swift test --disable-xctest` if it trips over missing XCTest
  (determine which in Phase 0).

---

## Phases

| # | Deliverable | Est. |
|---|---|---|
| **0** | **Toolchain spike — everything is blocked on this; write no features until green** | ½ d |
| 1 | `SbxKit` + ported tests. Green `swift test`, zero UI code | 1–2 d |
| 2 | `SbxServices` + shim tests. Milestone: a throwaway `swift run` CLI prints parsed `sbx ls` | 2 d |
| 3 | App shell + Builder read-only: menu bar, tab picker, `HSplitView`, Theme, tree, filter, git-only, async scan | 2 d |
| 4 | Builder interaction: tri-state control, covered-by, manifest + primary star, template/name/clone, preview, Copy, Run in iTerm, keyboard. **Milestone: launches a real sandbox** | 2–3 d |
| 5 | Builder dialogs: root picker + autocomplete, presets, save preset, toasts, reveal. **Builder at parity** | 1–2 d |
| 6 | Sandboxes tab: list, detail, args field + persistence, Run/Stop/Delete + alert, `requireKnownSandbox` | 2 d |
| 7 | Policies: scoped-first list, scope labels, add with validation, remove with re-validation. **Full parity** | 1–2 d |
| 8 | Polish: sbx-not-found banner + Settings sheet, temp sweep, light/dark pass, empty/error states, `install.sh`, README + CLAUDE.md, then decide the fate of `src/electron/` | 2 d |

**~14–18 working days.** Phases 1 and 2 carry all the correctness — do them slowly. Once they're
green, 3–7 are mostly view assembly.

### Phase 0 acceptance checklist — ✅ DONE (2026-09-08)

Minimal `Package.swift` (one `SbxKit` function, one `@Test`, a one-`Text` window). All 6 checks
passed. Actual scaffold: `Scripts/package_app.sh` + `Scripts/compile_and_run.sh` (copied from the
`macos-spm-app-packaging` skill's templates, customized) instead of the `bundle.sh`/`install.sh`
names used earlier in this doc — same job, skill-provided and tested tooling. `install.sh` (port
of the Electron app's `bundle-and-install.sh`, installing to `/Applications`) is still Phase 8's
to write; `compile_and_run.sh` only rebuilds-and-relaunches in place, which is all Phase 0 needed.

1. ✅ `swift build -c release` succeeds; `--show-bin-path` locates the binary.
2. ✅ `swift test` runs swift-testing — **but only via `Scripts/test.sh`, never plain `swift test`
   or manifest-level settings.** Two real CLT-only findings, both load-bearing for every phase
   from here on:
   - CLT ships `Testing.framework`, but SwiftPM doesn't add its Frameworks dir to the module
     search path, and the framework's own baked-in rpath
     (`@loader_path/../../../../../usr/lib/`) is computed for Xcode's toolchain layout — it lands
     one directory level off under bare CLT. Without extra `-F`/`-rpath` flags, `swift test` fails
     at "no such module 'Testing'", then at a `dlopen` failure on `lib_TestingInterop.dylib`.
   - **The fix must be passed as top-level `-Xswiftc`/`-Xlinker` arguments to the `swift test`
     invocation itself — not baked into the testTarget's `swiftSettings`/`linkerSettings` in
     `Package.swift`.** Verified by direct experiment: identical flags placed in the manifest's
     target-level `unsafeFlags` make `swift test` build successfully and exit 0 while **silently
     never invoking the test runner at all** — no output, no error, tests just don't run. The same
     flags passed on the command line work correctly. `Scripts/test.sh` wraps this; every future
     `swift test` invocation (CI, docs, muscle memory) must go through it, not run bare.
3. ✅ `Scripts/package_app.sh` produces a correctly structured `.app` — `Contents/{MacOS,Resources,
   Frameworks}`, all required `Info.plist` keys present and correctly interpolated
   (`NSAppleEventsUsageDescription` + the four folder-usage-description keys + `NSPrincipalClass`
   + `NSHighResolutionCapable`), registers with the system as `type="Foreground"` (dock icon +
   menu bar, not a background/UIElement app). **Not visually confirmed** — this session has no
   attached display (`screencapture` returns a solid black frame, `ioreg -c IODisplayConnect`
   finds no connected display), so "non-blurry text" specifically wasn't eyeballed; everything
   that predicts it (the two Info.plist keys) is in place.
4. ✅ `codesign --force --sign -` succeeds; `codesign -dv --verbose=4` shows a valid adhoc
   signature; `spctl --assess --type execute` → `accepted`. App launches and stays running (not
   crash-looping) across three separate launches during this spike.
5. ✅ AppleEvent to iTerm succeeds after the TCC prompt — confirmed via the probe's own result
   file (`appleEventProbe: OK — iTerm window opened.`), sent from within the real signed `.app`.
   Two things worth remembering for later phases:
   - **A blocking `Process.waitUntilExit()` call inside SwiftUI's `.task {}` freezes the app's
     entire main thread** for as long as a pending TCC dialog sits unanswered — the first version
     of this probe did exactly that. Fixed by running the `Process` call via `Task.detached`
     rather than synchronously on the main actor. This is precisely the reason
     `SbxServices/ProcessRunner` (Phase 2) uses a continuation-based async wait instead of
     `waitUntilExit()` directly — this spike is direct field evidence for that design choice, not
     just a theoretical concern.
   - **Ad-hoc (`--sign -`) signatures are not stable across rebuilds**, so TCC's Automation grant
     did not obviously carry over between two ad-hoc-signed builds produced minutes apart in this
     session — a fresh prompt (or at least a fresh multi-second/multi-minute AppleEvent delay)
     showed up again after a rebuild+repackage, even though the bundle identifier
     (`com.alexalbu.sbx-helper`) was unchanged. This matches the plan's own signing section
     ("macOS will either re-prompt on every rebuild or silently deny") but is now empirically
     confirmed, not just theoretical. **Recommendation for Phase 1+ day-to-day dev**: use the
     skill's `setup_dev_signing.sh` template to create one stable local self-signed identity
     instead of `--sign -`, so TCC grants survive rebuilds during active development. Ad-hoc
     stays correct for the final `install.sh` distribution build.
6. ✅ `~/Library/Application Support/sbx-helper-swift/` created and written
   (`configProbe: OK — wrote .../phase0-marker.txt`) on every launch, not TCC-gated, no
   surprises.

**Net effect on the rest of the plan:** nothing here changes SbxKit/SbxServices/UI phases 1–8 as
designed. It adds two concrete pieces of required tooling (`Scripts/test.sh`'s flags,
`setup_dev_signing.sh` for dev-loop signing) and one piece of hard evidence for a design decision
already made (async process execution off the main actor). Phase 0's throwaway files
(`Sources/SbxKit/Spike.swift`, `Tests/SbxKitTests/SpikeTests.swift`,
`Sources/SbxHelperApp/PhaseZeroProbes.swift`) are deleted at the start of Phase 1 / end of Phase 2
respectively, per their own doc comments.

---

## Verification

Per phase, and again at the end:

```console
$ cd src/macos
$ swift build -c release          # or: run-filtered.sh swift build -c release
$ ./Scripts/test.sh               # NOT plain `swift test` — see Phase 0 findings above
$ SIGNING_MODE=adhoc ./Scripts/package_app.sh release   # or ./Scripts/compile_and_run.sh --test
```

(`Scripts/install.sh`, installing the packaged `.app` into `/Applications` the way the Electron
app's `bundle-and-install.sh` does, is written in Phase 8.)

End-to-end, against the real `sbx` (v0.39.0 at `/opt/homebrew/bin/sbx`):

1. Launch the installed `.app` from `/Applications` (not `swift run`) — **this is the only way to
   catch the PATH and TCC problems**, which are invisible in a terminal-launched build.
2. Builder: change root to `/Users/alexalbu/repos/nho`, filter, toggle git-only, mark one folder
   editable and one read-only, confirm the ancestor/descendant lockout shows "covered by", set
   primary, pick a template from the live `sbx template ls` list, and check the preview matches
   what the Electron app produces for the same selection **byte for byte**.
3. Copy → paste into a terminal and confirm it runs. Then Run in iTerm → confirm a **new window**
   opens (not a reused one) and the sandbox starts.
4. Save a preset, quit, relaunch, load it — confirm relative paths resolved and the selection,
   template, name and `--clone` all came back.
5. Sandboxes: confirm the list matches `sbx ls` exactly (status, agent, ports, `:ro` suffixes).
   Select one, edit the agent-args tail, Run, quit, relaunch, reselect — the edited tail persists.
   Stop (disabled unless running), then Delete via the alert.
6. Policies: confirm sandbox-scoped rules sort first and are the only ones with a remove button;
   kit/global rules render but aren't removable. Add `example.com`, remove it, and verify against
   `sbx policy ls <name> --json` at each step.
7. Deliberately break `sbxPath` in the config and confirm the banner appears rather than an empty
   template list.

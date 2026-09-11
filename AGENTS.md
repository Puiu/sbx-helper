# sbx-helper — macOS app (`src/macos/`)

Active work is the native SwiftUI rewrite in `src/macos/`. `src/electron/` is FROZEN — read it for parity reference only, do not modify. `sbx-vm-configurator/` and `docs/` are out of scope.

Parity source: `src/electron/` JS + `src/electron/CLAUDE.md` (auto-loaded via `opencode.json`). Rationale/history: `src/macos/PLAN.md` — consult on demand, it is large.

## Commands (from `src/macos/`)

- `./Scripts/test.sh` — NEVER bare `swift test`. CLT's `Testing.framework` needs `-F/-rpath` flags passed on the command line; baking them into `Package.swift` as `unsafeFlags` builds cleanly but silently runs zero tests.
- `swift build -c release`
- `SIGNING_MODE=adhoc ./Scripts/package_app.sh release`
- Dev loop: `./Scripts/compile_and_run.sh [--test]`

## Toolchain (CLT only, no Xcode)

- SPM, zero package dependencies. `import Testing`, never XCTest. No `actool`/asset catalogs (colors in Swift, icon via `iconutil`). No ViewInspector/XCUITest; never write tests importing SwiftUI.
- Targets exist because SwiftPM can't link an `@main` executable into tests: `SbxKit` (pure logic, Foundation only) → `SbxServices` (process/sbx/terminal) → `SbxAppCore` (@Observable models, no SwiftUI) → `SbxHelperApp` (SwiftUI only). Keep testable logic in `SbxKit`; declare test-target deps explicitly in `Package.swift`.

## Gotchas that must survive

- Bundle id `com.alexalbu.sbx-helper` is stable forever (TCC Automation + folder grants keyed to it). Sign LAST — `Info.plist` edits invalidate. Ad-hoc (`--sign -`) re-prompts TCC on every rebuild; use a stable dev identity for iteration. Never hardened-runtime with ad-hoc, never App Sandbox.
- GUI `.app` gets launchd PATH (no Homebrew): `ToolLocator` resolves the absolute `sbx` path and prepends the prefix to child PATH. Preview/`.command` files still emit bare `sbx` (they run under the user's login shell in iTerm).
- Config `~/Library/Application Support/sbx-helper-swift/sbx-helper.json` — separate from Electron's file, same schema + new optional `sbxPath`, keep `port` on round-trip. Overrides: `SBX_HELPER_CONFIG`, `SBX_HELPER_SBX_PATH`. Lenient decode per-field (one bad field must not wipe presets); malformed JSON → defaults + banner, preserve bad file as `.bak`.
- Scanner parity: `.git` file (not just dir) counts as repo (worktrees); skip symlinks (`lstat` semantics); manual dot-prefix filter (not `.skipsHiddenFiles`); `localizedStandardCompare` sort; root always emitted even if unreadable.
- `ProcessRunner` (actor, never throws): drain both pipes concurrently past the output cap, gate resolution on stdout-EOF + stderr-EOF + termination (termination alone truncates), 200ms grace after termination for grandchild-held pipes, SIGTERM→SIGKILL escalation, never block main actor (`waitUntilExit` in `.task` freezes TCC prompts).
- Ported invariants (reason changed, rules didn't): `validateAgentArgs` caps (display integrity, not untrusted client); `quotePosix` byte-for-byte (`'\''` idiom, `tokenizeArgs`↔`quotePosix` round-trip); `findAnyConflict` as `buildArgs` precondition (hand-edited presets bypass UI); absolute-path + exists check before launch; `requireKnownSandbox` fresh on every mutating call (`sbx policy ls <bogus>` exits 0 with global rules); `removable` re-check before `policy rm`, always pass `--sandbox <name>`.

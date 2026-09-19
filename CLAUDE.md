# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`sbx-helper` is a desktop front end for driving the `sbx` (Docker Sandboxes) CLI: point it at a
folder, split subfolders into editable/read-only buckets, and it assembles a `sbx run ...`
command. A second tab manages existing sandboxes (list/stop/delete/re-run, edit network policy).

There are two implementations of the same app, plus a directory of Dockerfiles/scripts for
building the sandbox images the app launches:

- **`src/macos/`** — ACTIVE. Native SwiftUI rewrite, no Xcode/Electron dependency. This is where
  new work happens. See `src/macos/CLAUDE.md` for build commands, target layout, and a list of
  gotchas that must survive any refactor (TCC bundle-id stability, PATH resolution, config
  round-tripping, scanner parity, process draining, argv validation invariants).
- **`src/electron/`** — FROZEN. Do not modify. Kept only as the parity reference the Swift port
  was built against. See `src/electron/CLAUDE.md` for its architecture (the interesting part:
  `public/shared/*.mjs` is loaded by both the Node server and the browser, so the command preview
  the user sees is literally the code that runs — never re-implement that logic on one side only).
- **`sbx-vm-configurator/`** — Dockerfiles and build scripts for the Claude/OpenCode sandbox
  images `sbx run --template ...` launches, plus secret provisioning (`setup-secrets.sh`,
  `.env`/`.env.example`). Out of scope for app changes; see `sbx-vm-configurator/README.md`.

**When in doubt about scope: work in `src/macos/`. Never edit `src/electron/`** — it exists only
as a read-only spec for parity behavior.

## Commands

All from `src/macos/` (the active codebase):

```console
$ ./Scripts/test.sh                              # run tests — NEVER bare `swift test`
$ swift build -c release
$ SIGNING_MODE=adhoc ./Scripts/package_app.sh release
$ ./Scripts/compile_and_run.sh [--test]           # dev loop
$ ./Scripts/install.sh                            # build + install to /Applications
```

`./Scripts/test.sh` exists because the CLT's `Testing.framework` needs `-F`/`-rpath` flags passed
on the command line — baking them into `Package.swift` as `unsafeFlags` builds cleanly but
silently runs zero tests.

Electron reference (`src/electron/`, read-only): `node --test` runs its 149-test suite; do not run
`npm start`/`npm run package` there expecting to affect the shipped app — it's frozen.

## Architecture (src/macos)

SwiftPM can't link an `@main` executable target into tests, so logic is split into layered
targets, each testable independently:

```
SbxKit        pure logic, Foundation only (argv assembly, quoting, scanning, config codec)
  ↓
SbxServices   process spawning, tool location, terminal launch, config persistence
  ↓
SbxAppCore    @Observable models (AppModel, BuilderModel) + ScanService actor — no SwiftUI
  ↓
SbxHelperApp  SwiftUI views only (@main executable)
```

Keep testable logic in `SbxKit`; test targets declare their `SbxKit`/`SbxServices` dependencies
explicitly in `Package.swift` rather than relying on transitive visibility. No external package
dependencies — `import Testing`, never XCTest; no ViewInspector/XCUITest, never write a test that
imports SwiftUI.

Full details — TCC/signing order, PATH resolution for a double-clicked `.app`, config file
override precedence, directory-scanner parity rules, `ProcessRunner`'s pipe-draining contract, and
which validation invariants were ported from Electron and why — are in `src/macos/CLAUDE.md`.
Read it before touching any of those areas; they're easy to silently break.

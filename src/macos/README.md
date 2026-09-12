# sbx-helper (native macOS app)

A native macOS front end for driving the `sbx` (Docker Sandboxes) CLI —
no browser engine, no loopback server, a few MB instead of ~200MB.

Two tabs. **Builder**: point it at a folder, click subfolders into editable
and read-only buckets, and it assembles the `sbx run` command. Copy it, run
it in a new iTerm window straight from the app, or save the selection as a
named preset. **Sandboxes**: lists existing sandboxes (same detail as
`sbx ls`), lets you stop/delete/re-run one (agent args editable before
running), and edit its network policy (sandbox-scoped allow/deny rules).

## Install

```console
$ cd src/macos
$ ./Scripts/install.sh
```

This builds the release bundle, replaces `/Applications/sbx-helper.app`
(quitting any running copy first), and relaunches it. Day-to-day
iteration instead: `./Scripts/compile_and_run.sh [--test]`.

## First run permissions

Two macOS prompts are normal, each asked once:

- **Automation (iTerm)**: "sbx-helper opens a new iTerm2 window to run the
  sbx command you assembled." Required for Run in iTerm.
- **Folder access**: when you point the Builder at `~/Desktop`,
  `~/Documents`, `~/Downloads`, or an external volume. A denied folder
  shows as `unreadable` in the tree rather than crashing.

If a prompt was answered wrongly or TCC state goes stale:

```console
$ tccutil reset AppleEvents com.alexalbu.sbx-helper
```

then relaunch and approve again.

## Finding `sbx`

A double-clicked `.app` gets launchd's minimal `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin`), so a Homebrew `sbx` is invisible to it
by default. The app resolves the binary itself (config override →
well-known locations → your login shell) and shows a persistent
**"sbx not found — set its location in Settings."** banner if all of that
fails — never a silently empty template list. Open Settings (⌘,) to set
the absolute path explicitly.

## Config

`~/Library/Application Support/sbx-helper-swift/sbx-helper.json` — same
schema as the Electron app's file (presets can be copied over by hand),
plus an optional `sbxPath`. Overrides: `SBX_HELPER_CONFIG`,
`SBX_HELPER_SBX_PATH`. A malformed file falls back to defaults with a
banner, and the bad file is preserved as `.bak`.

## Verifying a build

```console
$ ./Scripts/test.sh                 # full suite (never bare `swift test`)
$ swift build -c release
$ SIGNING_MODE=adhoc ./Scripts/package_app.sh release
```

End-to-end (needs a sighted run against the real `sbx`): Builder
selection → preview matches the Electron app byte for byte → Copy and Run
in iTerm open a new window; presets survive quit/relaunch; Sandboxes list
matches `sbx ls`; policies add/remove round-trip against
`sbx policy ls <name> --json`; breaking `sbxPath` shows the banner.

## Uninstall

Delete `/Applications/sbx-helper.app`. Optionally also remove the config
directory above.

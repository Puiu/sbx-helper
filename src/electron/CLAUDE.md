# sbx-helper

A local app with two tabs. **Builder**: point it at a folder, click subfolders into two buckets
— editable and read-only — and it assembles
`sbx run --template <tpl> [--name <n>] [--clone] <agent> <primary> [<other editable>…] [<ro>:ro …]`.
Copy the command, run it directly in a new terminal, or save the selection as a named preset.
**Sandboxes**: lists existing sandboxes (same detail as `sbx ls`), lets you select one and
stop/delete/re-run it (agent args editable before running), and edit its network policy
(sandbox-scoped allow/deny rules only).

Two ways to run it, same app underneath:

- **Browser mode** — `node server.mjs`. Zero npm dependencies. Opens your browser.
- **Desktop mode** — `npm start` (dev), or the packaged `.app` (see below). Electron is the
  project's only dependency, needed for this mode alone; browser mode stays dependency-free.

## Commands

```console
$ node --test              # run the test suite (149 tests, node:test, zero deps)
$ node server.mjs           # browser mode
$ npm install && npm start   # desktop mode, dev window
$ ./bundle-and-install.sh    # rebuild + install to /Applications, quitting/replacing any
                              # running copy, then launches it — the normal way to pick up
                              # code changes in the installed app
```

## Architecture — the one thing to know before editing

`public/shared/*.mjs` (`command.mjs`, `selection.mjs`, `sandbox-commands.mjs`) are imported
**both** by the server (`server.mjs`, to build the real `argv` passed to `spawn`) **and** served
as-is to the browser (imported by `public/app.js`, for the live command preview). One
implementation of quoting, argument ordering, and validation — the preview you see is exactly
what runs, not a re-implementation of it. If a change touches command assembly or validation
rules, it belongs in `public/shared/`, not duplicated on either side.

```
server.mjs           node:http server — static files + JSON API + shell-outs
                       exports startServer()/stopServer(); only auto-runs when invoked directly
electron-main.mjs      desktop entry point — starts server.mjs, opens a native window at it
lib/                  server-only (node:fs, node:child_process) — never served to the browser
  config.mjs            load/save sbx-helper.json, preset path relativizing
  scan.mjs               eager directory-tree scan + path autocomplete
  templates.mjs           `sbx template ls` invocation + parsing
  terminal.mjs            launches iTerm2/Terminal.app, pbcopy, Finder reveal
  sandboxes.mjs           `sbx ls`/`sbx policy ls` invocation + parsing; generic `runSbx()` spawn wrapper
public/
  index.html, app.js, styles.css   — two tabs: Builder (existing) and Sandboxes
  shared/                imported by BOTH server and browser — see above
    command.mjs            `sbx run` (create) argv assembly + POSIX quoting
    selection.mjs           path-prefix / "no nested mounts" logic
    sandbox-commands.mjs     run (re-attach) / stop / rm / policy allow-deny-rm argv assembly
test/                  node --test (unit tests + one HTTP-level integration test)
test-fixtures/         NOT under test/ — node --test treats any file inside a directory named
                       "test" as a test file, so the fake `sbx` shim used by
                       test/server-sandboxes.test.mjs lives here instead
patches/               see "Patched dependency" below — do not delete as unused
```

## Security model

The server executes shell commands, so every `/api/*` route requires: binding to `127.0.0.1`
only, a `Host` header check (blocks DNS rebinding), and a random per-launch token every request
must carry. `POST /api/run` **never accepts a command string** — only a folder selection (paths +
settings), which the server rebuilds into `argv` itself via `public/shared/command.mjs`. Don't
add an endpoint that spawns a client-supplied string; that's a remote shell.

The Sandboxes tab's `/api/sandbox/*` routes widen this slightly, deliberately: `POST
/api/sandbox/run`'s agent-args tail (the part after `--`) *is* client-supplied argv — that's the
feature (edit the args, then re-run an existing sandbox). It's tokenized and validated
structurally (token count/length, no control characters) by `public/shared/sandbox-commands.mjs`,
appended after `--`, and passed to `spawn` without a shell — never through `sh -c` or string
concatenation. Every route re-validates the **sandbox name** against a fresh `sbx ls` on every
request (never cached) — an allowlist of names that actually exist, not just a syntax check; this
matters because `sbx policy ls <bogus-name> --json` exits 0 and returns the *global* rules, so
without this check the policy endpoints could be tricked into reading or (if a name check were
skipped) touching global policy under the guise of a sandbox that doesn't exist. Policy mutations
always pass `--sandbox <name>` (never omitted — omitting it silently targets the global policy),
and removal re-checks the target rule against a fresh policy list, refusing anything that isn't
sandbox-scoped and editable, so a client can't smuggle a global or kit rule's id through.

Both run routes (`apiRun`, `apiSandboxRun`) call an overridable module-level `launcher` (default
`launchInTerminal`) rather than that function directly — `startServer({ launcher })` swaps it in.
That's what lets `test/server-sandboxes.test.mjs` exercise those routes' validation and exact
argv without ever opening a real terminal window.

## Patched dependency — don't remove `patches/`

`patches/@electron+packager+18.4.4.patch` works around a real bug in the pinned
`@electron/packager`: on the Node version this was built with, its zip extraction step hangs
part-way through unpacking Electron itself (no error, no timeout — it just stops). The patch
swaps that one function to shell out to `/usr/bin/unzip`, which extracts the identical archive
correctly. `npm install`'s `postinstall` script reapplies it automatically. Without it,
`npm run package` will hang. If a future dependency bump seems to make this moot, confirm
`npm run package` still completes *without* the patch before removing it.

## Full documentation

`README.md` has the user-facing detail: every keyboard shortcut, the config file schema, how
"Run in iTerm" avoids AppleScript double-escaping, and the Electron/Gatekeeper notes for
`bundle-and-install.sh`.

# sbx-helper

A local web app with two tabs. **Builder**: point it at a folder, click folders into two
buckets — editable and read-only — and it assembles a `sbx run` command for you. Copy it, launch
it in a new iTerm2 window, or save the selection as a named preset. **Sandboxes**: manage
sandboxes you've already created — see the same detail `sbx ls` shows, select one to stop,
delete, or re-run it (with an editable agent-args tail), and edit its network policy.

Node backend, browser frontend. Built for macOS. Runs either as a plain browser-mode server
(zero npm dependencies) or as a native desktop app via Electron (the one dependency the project
has — see below).

## Browser mode

No install, no build step — Node.js (anything reasonably recent; built-in `node:test` is used)
is the only requirement.

```console
$ node server.mjs
```

This opens your browser on the app. First run creates `sbx-helper.json` beside `server.mjs` —
that's where the root folder, default template, and any saved presets live.

The server binds to `127.0.0.1` only and mints a random token on every launch (embedded in the
URL it opens for you); every API call has to carry it. Don't share that URL — anyone who has it
can launch sandboxes on your machine for as long as the server is running.

## Desktop app (Electron)

Same app, same server, opened in a native window instead of a browser tab — no terminal to
leave running, no tab to lose track of. This is the one place the project isn't zero-dependency:
Electron itself is an ~200MB npm package, needed either way you run it this way.

```console
$ npm install       # one-time; also applies the patch described below
$ npm start          # opens a window — for day-to-day dev use
$ npm run package     # builds a real, double-clickable sbx-helper.app
```

`npm run package` puts it at `out/sbx-helper-darwin-<arch>/sbx-helper.app` — drag it into
`/Applications`, or leave it in place and double-click it there. **It isn't code-signed or
notarized** (that needs a paid Apple Developer account), so the first launch will hit macOS
Gatekeeper's "unidentified developer" warning — right-click → **Open** to get past it once.

**To install it properly instead of running it out of `out/`**, use `./bundle-and-install.sh`.
It runs the two steps above, then quits any currently-running installed copy, replaces
`/Applications/sbx-helper.app` with the fresh build, strips the quarantine flag defensively, and
launches it — the normal way to pick up a code change: rerun it, it's idempotent.

Config lives at `~/Library/Application Support/sbx-helper/sbx-helper.json` in both Electron
modes — separate from browser mode's beside-the-script file, because a packaged app's own files
are read-only (see `electron-main.mjs`'s comment for why).

`npm run make` additionally zips the `.app` up, if you want to hand it to someone else.

**About `patches/`:** the version of `@electron/packager` that Forge currently pins hangs
part-way through extracting Electron's own zip on this Node version — a real upstream bug (a
plain `unzip` of the identical archive works fine; `patch-package` in the log at the time this
was set up traced it to `extract-zip`'s stream handling never firing an error or a completion
event on certain entries). The patch swaps that one function to shell out to `/usr/bin/unzip`
instead. `npm install` reapplies it automatically (`postinstall` script) — you shouldn't need to
think about this unless `npm run package` starts hanging again after a dependency bump, in which
case check whether upstream has fixed it and the patch can be dropped.

## Using it

- **Filter** narrows the tree as you type; check **git repos only** to hide folders that aren't
  (and don't contain) a git repository.
- **Change root** autocompletes as you type: it starts by showing your recent roots, then
  switches to live filesystem matches for whatever's after the last `/`. `↑`/`↓` to highlight a
  suggestion, `Enter`/`Tab` to accept it (which appends `/` so you can keep drilling), or click
  one. Plain `Enter` with nothing highlighted scans the typed path.
- Click a folder's **edit** / **ro** / **–** control to mark it editable, read-only, or
  unselected. Selecting a folder disables its parents and children — nested mounts don't make
  sense, and the row shows why it's covered.
- The **★** next to an editable folder in the Workspaces list sets it as the **primary**
  workspace — the first path passed to `sbx`, which it uses as the sandbox's working directory
  and to derive the default sandbox name.
- **Template**, **sandbox name**, and **--clone** live in the right-hand panel. The template
  dropdown is populated from `sbx template ls`; pick "Custom…" to type any name.
- The command at the bottom is always the literal argv that will run — **Copy**, **Run in
  iTerm** (opens a new window; the first time, macOS will ask you to approve Automation access),
  or **Save preset**.

**Keyboard:** `/` focuses the filter, `↑`/`↓` move through the tree, `←`/`→`
collapse/expand, `e` / `r` toggle editable/read-only on the highlighted row, `⌘↵` runs. Each
tab's shortcuts are active only while that tab is open; with a tab button itself focused, `←`/`→`
switches tabs.

## Sandboxes tab

- The list shows the same detail as `sbx ls`: sandbox name, agent, status, published ports, and
  workspaces (read-only ones keep their `:ro` suffix). It refreshes when you open the tab, after
  any action, and via the **refresh** button — there's no background polling.
- Click a row to select it (exactly one at a time). Selecting shows its network policy rules and
  three actions: **Run**, **Stop** (disabled unless it's running), and **Delete**.
- **Run** re-attaches with `sbx run --name <name> [-- <agent args>]`. For a `claude` sandbox the
  agent-args tail defaults to `--model opusplan`; other agents default to no tail. The tail is a
  plain text field — edit it before running, and your edit is remembered per sandbox (in
  `sbx-helper.json`) for next time. The command preview above the buttons is exactly what will
  run, same as the Builder tab's.
- **Delete** asks for confirmation first — `sbx rm --force` is irreversible and, per the CLI, also
  removes a sandbox that's currently in use (e.g. an open SSH connection), which the dialog says.
- **Network policies** lists every rule that applies to the sandbox: your own scoped rules first
  (each removable, allow or deny), then rules from a kit or the global policy underneath, shown
  for context but not editable here. Add a rule with the allow/deny select and a resource field
  (comma-separated hostnames, `*.example.com`, or `**` for everything) — it's always added scoped
  to this one sandbox, never globally.

## Config file

`sbx-helper.json`, next to `server.mjs`. Override the location with the `SBX_HELPER_CONFIG`
environment variable.

```jsonc
{
  "rootPath": "/Users/you/repos/nho",
  "recentRoots": ["/Users/you/repos/nho"],
  "defaultTemplate": "claude-sbx-dotnet10:v2",
  "agent": "claude",
  "maxDepth": 3,
  "ignoreFolders": [".git", "node_modules", "bin", "obj", ".vs", ".idea"],
  "port": 7777,
  "presets": [
    {
      "name": "consent+accesshub",
      "rootPath": "/Users/you/repos/nho",
      "template": "claude-sbx-dotnet10:v2",
      "sandboxName": null,
      "clone": false,
      "editable": ["Consent-register/NHO.0476.ConsentRegister.Web"],
      "readOnly": ["AccessHubPortal/NHO.AccessHub.Web"]
    }
  ],
  "sandboxArgs": {
    "24114-natt-sync-selskap": "--model opusplan"
  }
}
```

Preset folder paths are stored relative to that preset's own `rootPath`, so a preset stays valid
even if you move the whole checkout to a different path on the same machine.

`sandboxArgs` remembers the last agent-args tail you ran each sandbox with, keyed by sandbox
name, so the Sandboxes tab's args field starts where you left it rather than resetting to the
agent default every time.

## Project layout

```
server.mjs                 node:http server — static files + JSON API + shell-outs
                             exports startServer()/stopServer(); auto-runs only when run directly
electron-main.mjs           desktop entry point — starts server.mjs, opens a native window
package.json, forge.config.js   Electron + Electron Forge config (npm install/start/package)
patches/                    patch-package fix for an @electron/packager bug — see README above
lib/                        server-only helpers (uses node:fs, node:child_process)
  config.mjs                 load/save sbx-helper.json, preset path relativizing
  scan.mjs                   eager directory-tree scan
  templates.mjs               `sbx template ls` invocation + parsing
  terminal.mjs                launches iTerm2 / Terminal.app, pbcopy fallback
  sandboxes.mjs                `sbx ls` / `sbx policy ls` invocation + parsing, generic spawn wrapper
public/
  index.html, app.js, styles.css   two tabs: Builder and Sandboxes
  shared/
    command.mjs               `sbx run` (create) argv assembly + POSIX quoting
    selection.mjs              ancestor/descendant conflict rules, primary resolution
    sandbox-commands.mjs        run (re-attach) / stop / rm / policy allow-deny-rm argv assembly
test/                        node --test, zero dependencies (includes one HTTP-level integration test)
test-fixtures/               NOT under test/ — see the note in CLAUDE.md's project layout
```

`public/shared/*.mjs` is imported by **both** the server (to build the real argv for `spawn`)
and the browser (served as-is, imported by `app.js` for the live command preview). One
implementation of quoting and ordering — what you see previewed is exactly what runs.

## Tests

```console
$ node --test
```

Covers command assembly and quoting, the ancestor/descendant selection rules, config
load/save/round-trip (including a malformed-JSON fallback), the tree scanner, `sbx template ls`
parsing, the Sandboxes tab's argv builders and `sbx ls`/`sbx policy ls` parsers, and one
integration test that starts the real server against a fake `sbx` on `PATH` to exercise the
`/api/sandbox/*` routes' validation and the exact argv they'd spawn.

## Security notes

This server executes shell commands on your machine, so a couple of things are worth knowing:

- It only ever binds to `127.0.0.1`, and rejects any request whose `Host` header isn't
  `127.0.0.1` or `localhost` — this blocks DNS-rebinding attacks from a malicious webpage.
- Every `/api/*` call must carry the random token from the startup URL, or it's rejected.
- `/api/run` never accepts a raw command string — only a folder selection, which the server
  rebuilds into argv itself via `public/shared/command.mjs`. An endpoint that spawns whatever
  string a client posts would be a remote shell.
- The Sandboxes tab's `/api/sandbox/run` is the one place this widens: its agent-args tail (after
  `--`) is client-supplied argv, by design — you're editing the flags an existing sandbox re-runs
  with. It's validated structurally, never passed through a shell, and every route re-checks the
  sandbox name against a live `sbx ls` on each request so a request can't act on — or, for policy
  routes, silently fall through to — a sandbox that doesn't actually exist.

## How "Run in iTerm" works

`osascript`'s `write text "…"` needs AppleScript string escaping stacked on top of shell
quoting — a good way to end up running a silently different command than the one you saw. To
avoid that, the assembled (already-quoted) command is written to a temp `.command` script, and
the only thing AppleScript ever has to interpolate is that script's own path — a string this app
generated itself.

If iTerm2 isn't available, it falls back to `open -a iTerm` and then `open -a Terminal`.

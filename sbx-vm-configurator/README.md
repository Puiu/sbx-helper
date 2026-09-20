## Secrets setup (one-time per host)

API keys for new sandboxes live in `.env` (gitignored, never committed).
`.env.example` is the committed template.

```console
$ cp .env.example .env   # fill in real values
$ ./setup-secrets.sh     # requires jq
```

This stores `CONTEXT7_API_KEY`, `AZURE_DEVOPS_PAT`, `OPENCODE_API_KEY`,
`GITHUB_PAT`, `CLAUDE_CODE_OAUTH_TOKEN`, and `JEV_API_KEY` in sbx's secret
store and opens the matching network policy. `GITHUB_PAT` is stored twice: as a custom secret
(env var for tools that read it directly) and as the built-in `github`
**service** secret, which is what lets the sbx proxy authenticate git-over-HTTPS
traffic — the custom secret alone does not cover git, since git sends no auth
header for the proxy to rewrite. Recreate existing sandboxes (`sbx rm` +
`sbx run`) after adding secrets. Per-key details (hosts, fallback tiers,
troubleshooting) are in the sections below.

The script is safe to re-run after editing `.env`: existing custom secrets are
updated in place (their placeholder is preserved, so sandboxes already holding
the old placeholder keep working — only the real secret behind it changes) and
`jq` is required to detect them.

- Troubleshoot: `could not read Username for 'https://github.com'` inside a
  sandbox → the `github` **service** secret is missing (`sbx secret ls` shows
  no `service github` row). A custom secret on host `github.com` is not
  enough: git sends no auth header for the proxy to rewrite. Re-run
  `./setup-secrets.sh`, then recreate the sandbox.

---

Save the Dockerfile above as Dockerfile in an empty folder (plus statusline.sh if you're using it), and cd into that folder.

Build the image locally:
   `docker build -t claude-sbx-dotnet10:v1 .`

Export it to a tar file:
   `docker image save claude-sbx-dotnet10:v1 -o claude-sbx-dotnet10.tar`

Load the tar into the sandbox runtime's image store:
   `sbx template load claude-sbx-dotnet10.tar`

Run a sandbox from it in any project:
   `sbx run --template claude-sbx-dotnet10:v1 claude`

Verify inside the sandbox once it's up:
   `dotnet --version`


If you rebuild later (new tag, patch update, etc.), just repeat steps 2–4 with a new tag — sbx template ls will show every version you've loaded, and sbx template rm <tag> clears out old ones.

The image is based on `docker/sandbox-templates:claude-code-docker` so that a Docker daemon runs
inside the sandbox. This is required for Testcontainers-based integration tests. Verify with
`docker info` inside the sandbox. Do **not** switch back to the plain `claude-code` base — it has no
daemon.

Each sandbox has its own image store, so the first integration-test run in a fresh sandbox pulls
`postgres:14` and `testcontainers/ryuk`. Images persist across `sbx stop`/`sbx run` but are lost on
`sbx rm`.

The statusline is wired through `/etc/claude-code/managed-settings.json`, not
`~/.claude/settings.json`. `sbx` rewrites `~/.claude/settings.json` unconditionally on every sandbox
(re)create, so a `statusLine` entry placed there is silently destroyed. `/etc/claude-code` is untouched
by `sbx` and loads at Claude Code's highest-precedence (policy) tier, so it survives recreates. Don't
move the statusline wiring back to `~/.claude/settings.json`.

### Preinstalled skills (superpowers, Claude template `v5+`)

The image ships with the superpowers plugin baked in — no manual install
per sandbox:

- The managed `/etc/claude-code/managed-settings.json` pre-registers the
  `superpowers-marketplace` (`extraKnownMarketplaces`) and enables
  `superpowers@superpowers-marketplace` (`enabledPlugins`), so both survive
  sbx (re)creates.
- The plugin + marketplace caches (`~/.claude/plugins/…`) are pre-installed
  during `docker build` (HTTPS source, no SSH keys needed).

### Context7 docs lookup (Claude template `v5+`)

The image also ships with the Context7 plugin (`context7@context7-marketplace`,
marketplace `upstash/context7`): the `context7_resolve-library-id` /
`context7_query-docs` MCP tools plus the auto-triggering docs skill, the
`docs-researcher` agent, and `/context7:docs`. Same pattern as superpowers —
managed registration + enablement, caches pre-installed at build time.

It works without an API key (anonymous tier, lower rate limits). To use your
own plan, store the key once and allow the MCP host:

```console
$ export CONTEXT7_API_KEY="<paste-your-key>"   # host only, never commit it
$ sbx secret set-custom \
    --host mcp.context7.com \
    --env CONTEXT7_API_KEY \
    --value "$CONTEXT7_API_KEY"
$ sbx policy allow network mcp.context7.com:443
```

Recreate existing sandboxes after adding the secret. The plugin reads
`CONTEXT7_API_KEY` from the environment automatically; unset means anonymous
tier. Fallback if the pre-install had no network at build time:

```console
$ claude plugin install context7@context7-marketplace
```

Fallback: if the pre-install had no network at build time, run once inside
the sandbox (marketplace is already known via managed settings, no `add`
step needed):

```console
$ claude plugin install superpowers@superpowers-marketplace
$ claude plugin install context7@context7-marketplace
```

Rebuilding with a bumped tag is also how you pick up new superpowers /
Context7 releases. Note `claude/dotnet/build-sandbox.sh` builds from the
`sbx-vm-configurator/` root as context (that is where
`statusline-command.sh` lives).

### Jev decision support (Claude template `v7+`)

The image also ships [Jev](https://www.jevai.org/agent), a decision-support
service for coding agents: a remote MCP server (six `jev_*` tools — task
routing, model routing, tool-call guarding, research/claim checking, and
completion review) plus six Skills that tell Claude when to call each tool.

It's wired differently from superpowers/Context7 because of two constraints:

- The six `SKILL.md` files are installed at build time into
  `/etc/claude-code/.claude/skills/` (the enterprise tier), not
  `~/.claude/skills/` — same reasoning as the managed-settings statusline
  above: this location is untouched by sbx's per-sandbox rewrites. Upstream
  ships them without frontmatter, so a `name`/`description` block is
  prepended to each so Claude auto-triggers them correctly; bodies are
  otherwise verbatim.
- The MCP server is registered at user scope with the header
  `Authorization: Bearer ${JEV_API_KEY}`, literally — Claude Code expands
  `${VAR}` references in user/project-scope MCP config at session start, so
  the real key never enters the image. (It can't live in managed-settings.json's
  `managedMcpServers`, which rejects `${VAR}` and would bake in the literal
  key, and it can't go in `/etc/claude-code/managed-mcp.json`, which takes
  exclusive control of MCP and would suppress the Context7 server above.)

Like `CONTEXT7_API_KEY`, the key is injected at sandbox runtime for a single
host and needs its network policy opened. `./setup-secrets.sh` at the repo
root handles both from `.env`'s `JEV_API_KEY`; to do it by hand:

```console
$ export JEV_API_KEY="<paste-your-key>"   # host only, never commit it
$ sbx secret set-custom \
    --host www.jevai.org \
    --env JEV_API_KEY \
    --value "$JEV_API_KEY"
$ sbx policy allow network www.jevai.org:443
```

Recreate existing sandboxes after adding the secret. Verify inside a sandbox:

```console
$ claude mcp list          # `jev` should show as connected, not failed
$ claude mcp get jev       # confirm the header name only, no key value
```

`claude mcp list` failing with a `401` means the secret isn't bound to host
`www.jevai.org`; a timeout means the network policy above wasn't opened. If
`jev` is missing entirely after a sandbox recreate (rather than merely
disconnected), sbx is rewriting `~/.claude.json` the same way it rewrites
`~/.claude/settings.json` — re-add it by hand as a stopgap:

```console
$ claude mcp add --transport http jev --scope user https://www.jevai.org/mcp \
    --header 'Authorization: Bearer ${JEV_API_KEY}'
```

---

## OpenCode (.NET 10 template: `opencode/dotnet/`)

Same .NET 10 SDK + global tools as the Claude template, but based on
`docker/sandbox-templates:opencode-docker` (run it with `sbx run opencode`,
not `claude`). Managed config lives at `/etc/opencode/opencode.json`
(the Linux managed tier); the image only references the Zen key via
`{env:OPENCODE_API_KEY}` — the secret itself is never baked into the image.

### Supplying your OpenCode (Zen) API key

Sandboxes do not see your host's `~/.config/opencode/` or `auth.json`.
Store the key once in sbx's secret store; the sandbox proxy injects it
at runtime as `OPENCODE_API_KEY`:

```console
$ export OPENCODE_API_KEY="<paste-your-zen-key>"   # host only, never commit it
$ sbx secret set-custom \
    --host opencode.ai \
    --env OPENCODE_API_KEY \
    --value "$OPENCODE_API_KEY"
$ sbx policy allow network opencode.ai:443
```

Then build/load/run from `opencode/dotnet/` (or via its
`build-sandbox.sh`, defaults to tag `v3`):

```console
$ docker build -f Dockerfile -t opencode-sbx-dotnet10:v3 ../..
$ docker image save opencode-sbx-dotnet10:v3 -o opencode-sbx-dotnet10-v3.tar
$ sbx template load opencode-sbx-dotnet10-v3.tar
$ sbx run --template opencode-sbx-dotnet10:v3 opencode ~/my-project
```

Notes:

- If you added the secret after creating a sandbox, recreate it
  (`sbx rm` + `sbx run`) so the new env var is present inside.
- Verify inside: `opencode debug config` shows the resolved managed
  config; `/models` lists Zen models without pasting the key again.
- Troubleshoot: empty key → sandbox predates the secret (recreate);
  403/auth failure → secret stored against the wrong `--host`
  (must be `opencode.ai`); network denied → the `policy allow` step
  is missing.
- Direct provider keys (Anthropic/OpenAI/…) use the built-in path
  instead: `sbx secret set anthropic`, etc. — no `set-custom` needed.

### Preinstalled skills (superpowers + Context7, opencode template `v3+`)

Yes — the image ships with the superpowers and Context7 (`@upstash/context7-opencode`)
plugins baked in, so you never install them manually per sandbox:

- Both are declared in the managed `/etc/opencode/opencode.json`
  `"plugin"` array, which survives sbx (re)creates even though user-level
  `~/.config/opencode/` does not.
- Their install caches (`~/.cache/opencode/packages/…`) are pre-warmed during
  `docker build`, so first start needs no download. Context7 adds the
  `context7_resolve-library-id` / `context7_query-docs` MCP tools plus the
  auto-triggering `context7-mcp` skill.

Context7 works without an API key (anonymous tier). To use your own plan,
same pattern as the Zen key — the plugin reads `CONTEXT7_API_KEY` from the
environment automatically:

```console
$ export CONTEXT7_API_KEY="<paste-your-key>"   # host only, never commit it
$ sbx secret set-custom \
    --host mcp.context7.com \
    --env CONTEXT7_API_KEY \
    --value "$CONTEXT7_API_KEY"
$ sbx policy allow network mcp.context7.com:443
```

Recreate existing sandboxes after adding the secret.

Fallback: if the cache is ever cold (e.g. pre-warm had no network at build
time), opencode reinstalls the plugin automatically on first start — that
path needs `github.com` + npm registry network in the sandbox policy.

Adding more plugins: extend the `"plugin"` array in
`opencode/dotnet/Dockerfile`'s managed config and add a matching
`opencode plugin "<spec>" -g` pre-warm line, rebuild with a new tag, and
reload via `sbx template load`. Rebuilding with a bumped tag is also how
you pick up new superpowers releases (the pre-warm clones latest `main`).

---

## Claude (.NET 10 + Swift 6 template: `claude/dotnet-and-swift/`)

Combines the Claude .NET 10 template (`claude/dotnet/`) and the OpenCode Swift 6
template (`opencode/swift/`) into one image: same Claude base
(`docker/sandbox-templates:claude-code-docker`, run with `sbx run claude`),
managed settings, statusline, and .NET 10 SDK + global tools as
`claude/dotnet/`, plus the Swift 6 toolchain (via `swiftly`, pinned to
`--platform ubuntu24.04`) and its noble compat libs from `opencode/swift/`.
Use this when a project needs both toolchains in the same sandbox instead of
switching templates.

The noble-compat apt shim from `opencode/swift/` is guarded by the base
image's `/etc/os-release` codename: it only runs if the base isn't already
noble, since the Claude base wasn't verified to be resolute the way
`opencode-docker` is.

Build/load/run (or via its `build-sandbox.sh`, defaults to tag `v2`):

```console
$ cd claude/dotnet-and-swift
$ docker build -f Dockerfile -t claude-sbx-dotnet-and-swift:v2 ../..
$ docker image save claude-sbx-dotnet-and-swift:v2 -o claude-sbx-dotnet-and-swift-v2.tar
$ sbx template load claude-sbx-dotnet-and-swift-v2.tar
$ sbx run --template claude-sbx-dotnet-and-swift:v2 claude ~/my-project
```

Verify inside the sandbox:

```console
$ dotnet --version   # 10.x
$ swift --version    # 6.x
$ docker info        # daemon present (start-docker label)
```

Preinstalled skills (superpowers + Context7 + Jev) and the statusline work
exactly as described in the Claude `claude/dotnet/` sections above — same
managed `/etc/claude-code/managed-settings.json` mechanism, same secret
setup steps.

---

## OpenCode (.NET 10 + Swift 6 template: `opencode/dotnet-and-swift/`)

Combines the OpenCode .NET 10 template (`opencode/dotnet/`) and the OpenCode
Swift 6 template (`opencode/swift/`) into one image: same OpenCode base
(`docker/sandbox-templates:opencode-docker`, run with `sbx run opencode`),
managed config, statusline, and .NET 10 SDK + global tools as
`opencode/dotnet/`, plus the Swift 6 toolchain (via `swiftly`, pinned to
`--platform ubuntu24.04`) and its noble compat libs from `opencode/swift/`.
Use this when a project needs both toolchains in the same sandbox instead of
switching templates.

Unlike `claude/dotnet-and-swift/`, the noble-compat apt shim here is copied verbatim
and unguarded — `opencode-docker` is the exact base `opencode/swift/` already
targets and verified (2026-09) as Ubuntu 26.04 (resolute), so there is no
codename uncertainty to guard against.

Build/load/run (or via its `build-sandbox.sh`, defaults to tag `v1`):

```console
$ cd opencode/dotnet-and-swift
$ docker build -f Dockerfile -t opencode-sbx-dotnet-and-swift:v1 ../..
$ docker image save opencode-sbx-dotnet-and-swift:v1 -o opencode-sbx-dotnet-and-swift-v1.tar
$ sbx template load opencode-sbx-dotnet-and-swift-v1.tar
$ sbx run --template opencode-sbx-dotnet-and-swift:v1 opencode ~/my-project
```

Verify inside the sandbox:

```console
$ dotnet --version   # 10.x
$ swift --version    # 6.x
$ docker info        # daemon present (start-docker label)
```

Supplying the Zen API key, preinstalled skills (superpowers + Context7), and
the managed-config mechanism all work exactly as described in the OpenCode
`opencode/dotnet/` sections above — same `/etc/opencode/opencode.json`,
same secret setup steps.
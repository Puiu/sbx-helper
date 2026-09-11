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
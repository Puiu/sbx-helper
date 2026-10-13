# Managed instructions

## Filtered command output

For any shell command whose output is long and mostly noise — `dotnet build`, `dotnet restore`,
`dotnet test`, `swift build`, `npm install`, and similar — run it through `run-filtered.sh`
instead of invoking it directly:

    run-filtered.sh <command> [args...]

`run-filtered.sh` is on PATH (`/home/agent/.local/bin/run-filtered.sh`), so it works from any
project without a relative path. It captures full output to a log file and only prints: pass/fail,
matched error/warning lines, and a detected version string, plus the full log path for follow-up.
Prefer it over piping into `grep`/`head`/`tail` ad hoc for this kind of command.

Do not use it for commands whose output you need to see in full (e.g. `git diff`, test runners with
structured output) — it's specifically for noisy build/install/restore commands.

#!/usr/bin/env bash
#
# run-filtered.sh — run a long-output command (dotnet build/restore, npm install, etc.)
# and print only what matters: pass/fail, errors/warnings, and the final version string.
#
# Pattern: capture everything to a log, but only ever show a filtered slice of it —
# the same "don't dump raw output, grep for the signal" approach Anthropic uses for
# Bash tool output in Claude Code (prefer grep/head/tail over cat on big output).
#
# Usage:
#   scripts/run-filtered.sh <command> [args...]
#
# Examples:
#   scripts/run-filtered.sh dotnet restore ./NHO.CompanyHub.sln --configfile ./NuGet.config
#   scripts/run-filtered.sh dotnet build ./Src/CompanyHub.Api/CompanyHub.Api.csproj -c Release
#   scripts/run-filtered.sh npm install
#
# Full output is always preserved in the log file named at the end, so nothing is lost —
# this only controls what gets printed to the terminal.

set -uo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 2
fi

log_dir="${RUN_FILTERED_LOG_DIR:-/tmp/run-filtered}"
mkdir -p "$log_dir"
log_file="$log_dir/$(date +%Y%m%d-%H%M%S)-$$.log"

# Run the command, keep full output in the log, exit code of the command (not tee).
"$@" >"$log_file" 2>&1
status=$?

# Error/warning lines: common dotnet/npm/msbuild/node failure vocabulary.
errors=$(grep -Ei 'error[ :]|exception|fatal|failed|npm err!' "$log_file" | sort -u)
warnings=$(grep -Ei 'warn(ing)?[ :]' "$log_file" | sort -u)

# Version lines: dotnet/npm/nuget typically print one of these shapes.
#   "Version:      8.0.100"       (dotnet --info)
#   "-> 1.4.2"                     (npm install result)
#   "Restored ... (in X ms)."      (not a version, skip)
#   "1.2.3"                        (npm version / npm pkg version output)
#   "added 12 packages ... "       (not a version, skip)
version=$(grep -Eio '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9a-zA-Z]+)*' "$log_file" | tail -1)

if [[ $status -eq 0 ]]; then
  echo "✔ SUCCESS: $*"
else
  echo "✘ FAILED (exit $status): $*"
fi

if [[ -n "$errors" ]]; then
  echo
  echo "Errors:"
  echo "$errors" | sed 's/^/  /'
fi

if [[ -n "$warnings" && $status -ne 0 ]]; then
  echo
  echo "Warnings:"
  echo "$warnings" | sed 's/^/  /'
fi

if [[ -n "$version" ]]; then
  echo
  echo "Version: $version"
fi

echo
echo "Full log: $log_file"

exit "$status"

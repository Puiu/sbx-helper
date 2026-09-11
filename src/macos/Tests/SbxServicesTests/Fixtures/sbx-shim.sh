#!/bin/sh
# Fake `sbx` binary for SbxServicesTests, invoked directly by absolute path
# (ProcessRunner takes an absolute executable, not a PATH lookup — unlike
# the Electron test's test-fixtures/sbx-shim.js, this fixture never needs
# PATH manipulation). Logs the argv of EVERY invocation (reads included) as
# one JSON array per line to $SBX_SHIM_LOG, matching the JS fixture's
# logging contract, then answers canned JSON for `ls --json` and
# `policy ls <name> --json`, exits 0 for the mutating subcommands
# (stop / rm / policy allow|deny|rm), and exits 1 for anything else.
#
# Env knobs:
#   SBX_SHIM_FAIL_LS=1        -> `ls --json` exits 1 with a stderr message.
#   SBX_SHIM_OUTPUT_BYTES=N   -> print N 'x' bytes to stdout first (output-cap tests).
#   SBX_SHIM_SLEEP_SECONDS=N  -> sleep N seconds before responding (timeout tests).
#   SBX_SHIM_IGNORE_TERM=1    -> ignore SIGTERM. Combined with SLEEP_SECONDS this
#                                execs `sleep` after the trap so the ignored
#                                disposition (which POSIX preserves across exec,
#                                unlike other traps) actually reaches the pid
#                                ProcessRunner sends SIGTERM to — otherwise only
#                                this shell would ignore it, sleep would still die,
#                                and the shell would just keep waiting on nothing.
#   SBX_SHIM_PID_FILE=path    -> write this process's own $$ to `path` before
#                                anything else, so a test can later check
#                                whether that pid is still alive (e.g. after
#                                the SIGKILL escalation window).
#   SBX_SHIM_CLOSE_STDIN=1    -> close stdin immediately, before anything
#                                else, to reproduce a caller writing to a
#                                pipe whose read end is already gone (EPIPE).

if [ -n "$SBX_SHIM_PID_FILE" ]; then
  echo $$ > "$SBX_SHIM_PID_FILE"
fi

if [ -n "$SBX_SHIM_CLOSE_STDIN" ]; then
  exec 0<&-
fi

log() {
  json="["
  first=1
  for a in "$@"; do
    esc=$(printf '%s' "$a" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$first" = 1 ]; then first=0; else json="$json,"; fi
    json="$json\"$esc\""
  done
  json="$json]"
  printf '%s\n' "$json" >> "$SBX_SHIM_LOG"
}

log "$@"

if [ -n "$SBX_SHIM_IGNORE_TERM" ]; then
  trap '' TERM
  if [ -n "$SBX_SHIM_SLEEP_SECONDS" ]; then
    exec sleep "$SBX_SHIM_SLEEP_SECONDS"
  fi
fi

if [ -n "$SBX_SHIM_SLEEP_SECONDS" ]; then
  sleep "$SBX_SHIM_SLEEP_SECONDS"
fi

if [ -n "$SBX_SHIM_OUTPUT_BYTES" ]; then
  head -c "$SBX_SHIM_OUTPUT_BYTES" /dev/zero | tr '\0' 'x'
fi

if [ "$1" = "read-stdin" ]; then
  cat
  exit 0
fi

if [ "$1" = "ls" ]; then
  case " $* " in
    *" --json "*)
      if [ -n "$SBX_SHIM_FAIL_LS" ]; then
        echo "sbx: simulated failure (SBX_SHIM_FAIL_LS)" >&2
        exit 1
      fi
      cat <<'JSON'
{"sandboxes":[
  {"name":"test-sandbox-1","id":"id-1","agent":"claude","status":"running","workspaces":["/tmp/ws1"],"ports":[]},
  {"name":"test-sandbox-2","id":"id-2","agent":"opencode","status":"stopped","workspaces":["/tmp/ws2"],"ports":[]}
]}
JSON
      exit 0
      ;;
  esac
fi

if [ "$1" = "policy" ] && [ "$2" = "ls" ]; then
  name="$3"
  cat <<JSON
{"rules":[
  {"id":"removable-rule-id","name":"removable-rule-id","scope":"sandbox:$name","resource_type":"network","decision":"deny","resources":["ads.example.com"],"origin":"local","status":"active","editable":true},
  {"id":"default-ai-services","name":"default-ai-services","scope":"global","resource_type":"network","decision":"allow","resources":["api.anthropic.com:443"],"origin":"local","status":"active","editable":true}
]}
JSON
  exit 0
fi

if [ "$1" = "template" ] && [ "$2" = "ls" ]; then
  cat <<'TABLE'
REPOSITORY                    TAG
claude-sbx-dotnet10            v2
claude-sbx-python              v1
TABLE
  exit 0
fi

case "$1" in
  stop) exit 0 ;;
  rm) exit 0 ;;
  policy)
    case "$2" in
      allow|deny|rm) exit 0 ;;
    esac
    ;;
esac

exit 1

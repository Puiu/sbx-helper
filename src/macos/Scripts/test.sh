#!/usr/bin/env bash
# `swift test`, wrapped to work around two Command Line Tools quirks with
# swift-testing (no Xcode installed on this machine — see PLAN.md Phase 0):
#
#   1. CLT ships Testing.framework, but SwiftPM doesn't add CLT's Frameworks
#      dir to the module search path on its own -> "no such module 'Testing'".
#   2. Testing.framework's own rpath (@loader_path/../../../../../usr/lib/)
#      is computed for Xcode's toolchain layout and lands one directory
#      level off under bare CLT, so dlopen of the test bundle fails on
#      lib_TestingInterop.dylib at runtime without an explicit extra rpath.
#
# IMPORTANT: these flags must be passed here, as top-level `-Xswiftc`/
# `-Xlinker` arguments to `swift test` itself — NOT baked into the
# testTarget's `swiftSettings`/`linkerSettings` in Package.swift. Verified
# empirically: identical flags placed in the manifest's target-level
# `unsafeFlags` make `swift test` build successfully but silently skip
# running the tests at all (exit 0, "Build complete!", no test output,
# no error) — apparently unsafeFlags on a testTarget suppress the actual
# test-execution step. Passing the same flags on the command line does not
# have this problem.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_DEVELOPER_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

exec swift test \
  -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT_DEVELOPER_LIB" \
  "$@"

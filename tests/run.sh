#!/bin/bash
# Builds and runs the checks that don't need hardware.
#   tests/run.sh [focus dump .json with "keymap.custom" and "superkeys.map" from a Defy]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/build"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  "$here/src/Config.swift" "$here/src/Keys.swift" "$here/src/Keymap.swift" "$here/src/Log.swift" "$here/src/ConfigStore.swift" "$here/src/Focus.swift" "$here/src/KeyboardModel.swift" "$here/tests/main.swift" \
  -o "$here/build/tests"
DYGMA_AUTO_MOUSE_HELPER_LOG="$here/build/tests.log" "$here/build/tests" "$@"

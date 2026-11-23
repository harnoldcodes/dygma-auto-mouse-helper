#!/bin/bash
# Draws the settings window and the menu bar icon to PNGs, light and dark.
#   tests/render.sh <out dir> <focus dump .json with "keymap.custom" and "superkeys.map">
#     every state, with the layers from that dump, your Bazecor layer names and the devices
#     plugged in (Input Monitoring for the terminal lists them). For checking a change only:
#     never publish these.
#   tests/render.sh <out dir> --docs
#     the README's screenshots, from made-up data only (tools/screenshots.sh runs this)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/build" "$1"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  $(ls "$here"/src/*.swift | grep -v '/main.swift$') "$here/tests/render/main.swift" -o "$here/build/render" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$here/src/Info.plist"  # the version shown
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The settings go to a fresh file. For --docs it sits where a real one would, under a stand-in
# home folder, so the window shows ~/.config/dygma-auto-mouse-helper/config.json5.
mkdir -p "$tmp/home/.config/dygma-auto-mouse-helper"
HOME="$tmp/home" DYGMA_AUTO_MOUSE_HELPER_LOG="$tmp/render.log" "$here/build/render" "$@" \
  --config "$tmp/home/.config/dygma-auto-mouse-helper/config.json5"

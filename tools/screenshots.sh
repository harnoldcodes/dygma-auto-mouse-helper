#!/bin/bash
# The README's screenshots, in docs/screenshots: each settings tab and the menu bar icon,
# light and dark, drawn from made-up data (a sample keymap, layer names and devices; never
# yours). Two runs on the same Mac give identical files.
#
#   tools/screenshots.sh           draw them again
#   tools/screenshots.sh --check   fail if the committed ones aren't what this code draws
#
# Run it before every release: tools/release.sh checks the tag with --check.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dir="$here/docs/screenshots"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
"$here/tests/render.sh" "$tmp/out" --docs >/dev/null

if [[ "${1:-}" == --check ]]; then
  if ! diff -rq "$tmp/out" "$dir" >"$tmp/diff" 2>&1; then
    sed -e "s|$tmp/out|new|g" -e "s|$here/||g" "$tmp/diff" >&2
    echo "docs/screenshots is out of date: run tools/screenshots.sh, look at them, and commit them" >&2
    exit 1
  fi
  echo "==> screenshots up to date"
else
  rm -rf "$dir"
  mkdir -p "$(dirname "$dir")"
  mv "$tmp/out" "$dir"
  echo "==> $(ls "$dir" | wc -l | tr -d ' ') screenshots in docs/screenshots"
fi

#!/bin/bash
# Publishes a release: builds the app from a tag, attaches it to the tag's GitHub release
# (making the release if there is none) and points the Homebrew cask at it.
#
#   tools/release.sh v0.1.0 [notes.md] [--readme-unchanged]
#
# Without a notes file, the release notes are the tag's message. Afterwards, commit and
# push Casks/dygma-auto-mouse-helper.rb.
#
# Every release updates the README and its screenshots, so this refuses a tag whose
# docs/screenshots aren't what its code draws (tools/screenshots.sh), or whose README.md
# hasn't changed since the previous release (--readme-unchanged: nothing in it needed to).
#
# The app is built from the tag's src/ and assets/ with this checkout's install.sh, for
# both Apple silicon and Intel, and signed with the self-signed certificate install.sh
# keeps in ~/.local/state/dygma-auto-mouse-helper. macOS ties the app's permissions to that
# certificate, so every release has to be signed with the same one, from the same Mac:
# with another, everyone who updates grants Input Monitoring and Accessibility again.
set -euo pipefail

repo=harnoldcodes/dygma-auto-mouse-helper
here=$(cd "$(dirname "$0")/.." && pwd)
readme_unchanged=0
args=()
for a in "$@"; do
  if [[ "$a" == --readme-unchanged ]]; then readme_unchanged=1; else args+=("$a"); fi
done
tag=${args[0]:?usage: tools/release.sh <tag> [notes.md] [--readme-unchanged]}
notes=${args[1]:-}
version=${tag#v}
cask="$here/Casks/dygma-auto-mouse-helper.rb"
zip_name="Dygma-Auto-Mouse-Helper-$version.zip"

git -C "$here" rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "no tag $tag" >&2; exit 1; }
git -C "$here" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || { echo "push $tag first" >&2; exit 1; }
plist_version=$(git -C "$here" show "$tag:src/Info.plist" | sed -n 's|.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*|\1|p')
[[ "$plist_version" == "$version" ]] || { echo "$tag's Info.plist says $plist_version" >&2; exit 1; }

prev=$(git -C "$here" describe --tags --abbrev=0 "$tag^" 2>/dev/null || true)
if [[ -n "$prev" && $readme_unchanged == 0 ]] && git -C "$here" diff --quiet "$prev" "$tag" -- README.md; then
  echo "README.md hasn't changed since $prev: update it for $tag, or pass --readme-unchanged" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tree" "$tmp/src"
git -C "$here" archive "$tag" | tar -x -C "$tmp/tree"
if [[ -x "$tmp/tree/tools/screenshots.sh" ]]; then
  "$tmp/tree/tools/screenshots.sh" --check || { echo "(in $tag)" >&2; exit 1; }
fi
git -C "$here" archive "$tag" src assets | tar -x -C "$tmp/src"
cp "$here/install.sh" "$tmp/src/"
"$tmp/src/install.sh" --build-only --universal
app="$tmp/src/build/Dygma Auto-Mouse Helper.app"
lipo -info "$app/Contents/MacOS/dygma-auto-mouse-helper"

mkdir -p "$here/build"
rm -f "$here/build/$zip_name"
ditto -c -k --sequesterRsrc --keepParent "$app" "$here/build/$zip_name"
sha=$(shasum -a 256 "$here/build/$zip_name" | cut -d' ' -f1)
echo "==> $here/build/$zip_name ($sha)"

if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" "$here/build/$zip_name" -R "$repo" --clobber
  echo "==> replaced $zip_name on the $tag release"
else
  if [[ -z "$notes" ]]; then
    notes="$tmp/notes.md"
    git -C "$here" tag -l --format='%(contents:body)' "$tag" >"$notes"
  fi
  title=$(git -C "$here" tag -l --format='%(contents:subject)' "$tag")
  gh release create "$tag" "$here/build/$zip_name" -R "$repo" --verify-tag --title "${title:-$tag}" --notes-file "$notes"
  echo "==> released $tag"
fi

sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
echo "==> $cask now points at $version; commit and push it"

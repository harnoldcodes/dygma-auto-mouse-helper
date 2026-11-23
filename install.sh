#!/bin/bash
# Builds Dygma Auto-Mouse Helper from this checkout and installs it for the current user:
#   ~/Applications/Dygma Auto-Mouse Helper.app      the app (it lives in the menu bar), or in
#                                                 /Applications in place of the Homebrew release
#   ~/.config/dygma-auto-mouse-helper/config.json5   your settings (the app writes it)
#   ~/Library/Logs/dygma-auto-mouse-helper.log       its log
# Run it again after pulling a new version: it keeps your settings and the permissions.
# A build from a git checkout is a dev build: its version says which commit it is, as in
# 0.1.0-dev+e8a0d29 (.dirty: with changes not yet committed).
#
#   ./install.sh               build, install and open the app
#   ./install.sh --release     go back to the official release (installed with Homebrew)
#   ./install.sh --build-only  build "./build/Dygma Auto-Mouse Helper.app" and stop there
#   --universal                build for both Apple silicon and Intel (as releases are)
set -euo pipefail

name=dygma-auto-mouse-helper
label=io.github.harnoldcodes.dygma-auto-mouse-helper
here=$(cd "$(dirname "$0")" && pwd)
bundle="Dygma Auto-Mouse Helper.app"
user_app="$HOME/Applications/$bundle"
system_app="/Applications/$bundle"  # where the Homebrew cask installs it
cask=dygma-auto-mouse-helper
config_dir="$HOME/.config/$name"
state="$HOME/.local/state/$name"
log_file="$HOME/Library/Logs/$name.log"

build_only=0
universal=0
to_release=0
for arg in "$@"; do
  case "$arg" in
    --build-only) build_only=1 ;;
    --universal) universal=1 ;;
    --release) to_release=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

[[ "$(uname)" == Darwin ]] || { echo "dygma-auto-mouse-helper runs on macOS only" >&2; exit 1; }
if (( $(sw_vers -productVersion | cut -d. -f1) < 13 )); then
  echo "Dygma Auto-Mouse Helper needs macOS 13 (Ventura) or later" >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Install Apple's Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

running() { pgrep -qx "$name"; }
quit_app() {
  if running; then
    osascript -e "tell application id \"$label\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do running || break; sleep 0.1; done
    if running; then pkill -x "$name" || true; sleep 0.5; fi
    echo "==> quit the running copy"
  fi
}
# A copy in ~/Applications: take its login item off before removing it (the remaining
# copy adds its own when it starts).
remove_user_copy() {
  [[ -d "$user_app" ]] || return 0
  "$user_app/Contents/MacOS/$name" --remove-login-item >/dev/null 2>&1 || true
  rm -rf "$user_app"
  echo "==> removed $user_app, so only one copy is installed"
}
brew_has_cask() { command -v brew >/dev/null && brew list --cask "$cask" >/dev/null 2>&1; }

# --- Back to the release ---------------------------------------------------------------
if ((to_release)); then
  if ! brew_has_cask; then
    echo "The release is installed with Homebrew, and it isn't:" >&2
    echo "  brew tap harnoldcodes/dygma-auto-mouse-helper https://github.com/harnoldcodes/dygma-auto-mouse-helper" >&2
    echo "  brew trust harnoldcodes/dygma-auto-mouse-helper" >&2
    echo "  brew install --cask $cask" >&2
    exit 1
  fi
  quit_app
  remove_user_copy
  brew reinstall --cask "$cask"
  open "$system_app"
  echo "==> opened the release: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$system_app/Contents/Info.plist")"
  exit 0
fi

# --- Signing ---------------------------------------------------------------------------
# macOS ties the Input Monitoring and Accessibility permissions to the app's signature.
# An ad-hoc signature changes with every build, which would mean granting them again after
# every update. So the helper is signed with a self-signed certificate made here once and
# kept in a keychain of its own (with a random password beside it, readable only by you).
# Its permissions then carry over to new builds, as they do for apps from a developer.
# Nothing here asks for your password: the keychain isn't your login keychain.
kc="$state/signing.keychain-db"
pwfile="$state/signing.pass"
cn="Dygma Auto-Mouse Helper (local signing)"
tmp=$(mktemp -d)
orig_list=()
cleanup() {
  # put the keychain search list back if the signing keychain was added to it
  if ((${#orig_list[@]})); then security list-keychains -d user -s "${orig_list[@]}"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

if [[ ! -f "$kc" || ! -s "$pwfile" ]]; then
  mkdir -p "$state"
  if [[ -f "$kc" ]]; then security delete-keychain "$kc"; fi
  (umask 077; /usr/bin/openssl rand -hex 24 > "$pwfile")
  pw=$(<"$pwfile")
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $cn
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$cn" \
    -out "$tmp/id.p12" -passout "pass:$pw"
  security create-keychain -p "$pw" "$kc"
  security set-keychain-settings "$kc"  # no auto-lock
  security unlock-keychain -p "$pw" "$kc"
  security import "$tmp/id.p12" -k "$kc" -P "$pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null
  echo "==> created the signing certificate (in $kc)"
fi
security unlock-keychain -p "$(<"$pwfile")" "$kc"
cert=$(security find-certificate -c "$cn" -Z "$kc" | sed -n 's/^SHA-1 hash: //p')

# --- Build -----------------------------------------------------------------------------
echo "==> building"
new="$tmp/$bundle"
mkdir -p "$new/Contents/MacOS"
archs=("$(uname -m)")
if ((universal)); then archs=(arm64 x86_64); fi
bins=()
for arch in "${archs[@]}"; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework Carbon -framework SwiftUI -framework IOKit -framework CoreGraphics -framework ServiceManagement \
    "$here"/src/*.swift -o "$tmp/$name-$arch"
  bins+=("$tmp/$name-$arch")
done
lipo -create "${bins[@]}" -output "$new/Contents/MacOS/$name"
cp "$here/src/Info.plist" "$new/Contents/Info.plist"
# A build from a git checkout is a dev build: stamp its version with the commit. (Releases
# are built from an export of the tag, which has no .git.)
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$new/Contents/Info.plist")
if git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
  version="$version-dev+$(git -C "$here" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$here" status --porcelain -- src assets)" ]]; then version="$version.dirty"; fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$new/Contents/Info.plist"
fi
echo "==> version $version"
mkdir -p "$new/Contents/Resources"
cp "$here/assets/AppIcon.icns" "$new/Contents/Resources/AppIcon.icns"
# codesign only finds identities in the keychain search list, so add the signing keychain
# for this one call; cleanup() puts the list back if anything fails.
while IFS= read -r k; do orig_list+=("$k"); done \
  < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
security list-keychains -d user -s "${orig_list[@]}" "$kc"
codesign --force --sign "$cert" --identifier "$label" "$new" 2>&1 | grep -v 'replacing existing signature' || true
security list-keychains -d user -s "${orig_list[@]}"
orig_list=()
codesign --verify --strict "$new"

if ((build_only)); then
  rm -rf "$here/build/$bundle"
  mkdir -p "$here/build"
  mv "$new" "$here/build/"
  echo "==> built $here/build/$bundle"
  exit 0
fi

# --- Install ---------------------------------------------------------------------------
quit_app

# One copy at a time: with the Homebrew release installed, a dev build goes in its place
# (./install.sh --release puts the release back), and a copy in ~/Applications goes.
if [[ -d "$system_app" ]]; then
  app="$system_app"
  remove_user_copy
else
  app="$user_app"
fi

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
if [[ "$(cdhash "$new")" != "$(cdhash "$app" 2>/dev/null || true)" ]]; then
  mkdir -p "$(dirname "$app")"
  rm -rf "$app"
  mv "$new" "$app"
  echo "==> installed $app"
  if [[ "$app" == "$system_app" ]] && brew_has_cask; then
    echo "    (in place of the Homebrew release; ./install.sh --release puts that back)"
  fi
else
  echo "==> $app is already this build"
fi

config="$config_dir/config.json5"
if [[ -f "$config" ]]; then
  echo "==> settings: $config (kept)"
  "$app/Contents/MacOS/$name" --check-config "$config" | grep '^warning' || true
else
  echo "==> settings: the app writes $config when it starts"
fi

open "$app"
cat <<EOF
==> opened Dygma Auto-Mouse Helper; its icon is in the menu bar (log: $log_file)

The first time, it asks for two permissions in System Settings > Privacy & Security:
  - Input Monitoring  (to read the trackball)
  - Accessibility     (to scroll and to catch the scroll key)
Its window shows which are still missing. Later builds keep them.
EOF

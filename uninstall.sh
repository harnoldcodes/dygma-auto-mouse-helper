#!/bin/bash
# Removes Dygma Auto-Mouse Helper: quits it, stops it starting at login and deletes the app.
#   ./uninstall.sh          keep your settings and the signing certificate, so a
#                           reinstall picks up where it left off, permissions included
#   ./uninstall.sh --purge  also delete the settings, the certificate, the log and the
#                           permissions
set -euo pipefail

name=dygma-auto-mouse-helper
label=io.github.harnoldcodes.dygma-auto-mouse-helper
app="$HOME/Applications/Dygma Auto-Mouse Helper.app"
system_app="/Applications/Dygma Auto-Mouse Helper.app"  # the Homebrew cask's, or a dev build in its place
config_dir="$HOME/.config/$name"
state="$HOME/.local/state/$name"
log_file="$HOME/Library/Logs/$name.log"
login_plist="$HOME/Library/LaunchAgents/$label.login.plist"  # start at login, when macOS refuses a login item

purge=0
case "${1:-}" in
  "") ;;
  --purge) purge=1 ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

if pgrep -qx "$name"; then
  osascript -e "tell application id \"$label\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -qx "$name" || break; sleep 0.1; done
  pkill -x "$name" 2>/dev/null || true
  echo "==> quit the app"
fi
for a in "$app" "$system_app"; do
  if [[ -x "$a/Contents/MacOS/$name" ]]; then "$a/Contents/MacOS/$name" --remove-login-item || true; fi
done
rm -f "$login_plist"
rm -rf "$app"
if command -v brew >/dev/null && brew list --cask dygma-auto-mouse-helper >/dev/null 2>&1; then
  brew uninstall --cask dygma-auto-mouse-helper
else
  rm -rf "$system_app"
fi
echo "==> removed the app and its login item"

if ((purge)); then
  [[ -f "$state/signing.keychain-db" ]] && security delete-keychain "$state/signing.keychain-db" || true
  rm -rf "$state" "$config_dir" "$log_file"
  tccutil reset Accessibility "$label" >/dev/null 2>&1 || true
  tccutil reset ListenEvent "$label" >/dev/null 2>&1 || true
  echo "==> removed the settings, the signing certificate, the log and the permissions"
  echo "    (if Dygma Auto-Mouse Helper is still listed under Privacy & Security, remove it with -)"
else
  echo "    kept: $config_dir (settings), $state (signing certificate)"
fi

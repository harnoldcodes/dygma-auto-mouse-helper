#!/bin/bash
# Rebuilds assets/AppIcon.icns from assets/AppIcon.svg, drawn by Google Chrome (headless).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/AppIcon.iconset"
cat > "$tmp/page.html" <<HTML
<!doctype html><style>html,body{margin:0;background:transparent}img{display:block;width:1024px;height:1024px}</style>
<img src="file://$here/assets/AppIcon.svg">
HTML
"$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --allow-file-access-from-files --force-device-scale-factor=1 --window-size=1024,1024 \
  --screenshot="$tmp/1024.png" "file://$tmp/page.html" 2>/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/1024.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/1024.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$here/assets/AppIcon.icns"
echo "wrote $here/assets/AppIcon.icns"

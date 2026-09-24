#!/bin/bash
# Builds "VibePulse Bar.app" from this package.
#
#   tools/vibepulse-bar/build-app.sh             # build into tools/vibepulse-bar/dist/
#   tools/vibepulse-bar/build-app.sh --install   # ...then replace ~/Applications/VibePulse Bar.app and open it
#   tools/vibepulse-bar/build-app.sh --previews DIR   # render the menu fixtures as PNGs into DIR
#
# The bundle is ad-hoc signed: it runs on the Mac that built it. It embeds
# no secrets; the tokenserver it supervises reads its own credentials.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
app_name="VibePulse Bar"
bundle_id="se.torget.vibepulse-bar"
dist="$here/dist"
app="$dist/$app_name.app"

install=0
previews=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) install=1 ;;
    --previews) previews="${2:?--previews needs a directory}"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$here"
swift build -c release --product VibePulseBar
binary="$(swift build -c release --show-bin-path)/VibePulseBar"

if [ -n "$previews" ]; then
  mkdir -p "$previews"
  "$binary" --render-previews "$previews" "$here/Tests/VibePulseBarCoreTests/Fixtures"
  exit 0
fi

describe="$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo "0.0.0")"
short_version="${describe#v}"
short_version="${short_version%%-*}"
case "$short_version" in [0-9]*) ;; *) short_version="0.0.0" ;; esac
build_number="$(git -C "$repo" rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/VibePulseBar"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>VibePulseBar</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short_version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>VPBuildDescription</key><string>$describe</string>
  <key>VPRepositoryRoot</key><string>$repo</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. VibePulse contributors.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$app" 2>&1 | sed '/replacing existing signature/d'
echo "built $app ($describe)"

if [ "$install" = 1 ]; then
  target="$HOME/Applications/$app_name.app"
  if pgrep -f "$target/Contents/MacOS/VibePulseBar" >/dev/null; then
    # SIGTERM is the app's quit path: it stops the tokenserver it owns
    # first (SIGINT, so the server's cleanup runs), then exits.
    pkill -TERM -f "$target/Contents/MacOS/VibePulseBar" || true
    for _ in $(seq 1 150); do
      pgrep -f "$target/Contents/MacOS/VibePulseBar" >/dev/null || break
      sleep 0.1
    done
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$target"
  cp -R "$app" "$target"
  open "$target"
  echo "installed $target"
fi

#!/bin/bash
# Build AIQuota.app and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AIQuota.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp Resources/*.svg "$APP/Contents/Resources/"

build() {  # $1 = arch
  swiftc -O -swift-version 5 -target "$1-apple-macos13.0" \
    -framework AppKit -framework ServiceManagement -framework UserNotifications \
    Sources/*.swift -o "build/AIQuota-$1"
}

if [[ "${1:-}" == "--release" ]]; then
  # Universal binary (Apple Silicon + Intel), zipped for GitHub Releases. Not installed.
  build arm64; build x86_64
  lipo -create build/AIQuota-arm64 build/AIQuota-x86_64 -output "$APP/Contents/MacOS/AIQuota"
  codesign --force --sign - "$APP" >/dev/null
  (cd build && rm -f AIQuota.zip && ditto -c -k --keepParent AIQuota.app AIQuota.zip)
  echo "Release: build/AIQuota.zip"
  exit 0
fi

build "$(uname -m)"
mv "build/AIQuota-$(uname -m)" "$APP/Contents/MacOS/AIQuota"
codesign --force --sign - "$APP" >/dev/null

mkdir -p "$HOME/Applications"
pkill -x AIQuota 2>/dev/null && sleep 0.5 || true
rm -rf "$HOME/Applications/AIQuota.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed: $HOME/Applications/AIQuota.app"

[[ "${1:-}" == "--no-open" ]] || open "$HOME/Applications/AIQuota.app"

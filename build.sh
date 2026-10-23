#!/bin/bash
# Build VibeToken.app and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/VibeToken.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources" && cp Resources/*.svg "$APP/Contents/Resources/"

build() {  # $1 = arch
  swiftc -O -swift-version 5 -target "$1-apple-macos13.0" \
    -framework AppKit -framework ServiceManagement -framework UserNotifications \
    Sources/*.swift -o "build/VibeToken-$1"
}

if [[ "${1:-}" == "--release" ]]; then
  # Universal binary (Apple Silicon + Intel), zipped for GitHub Releases. Not installed.
  build arm64; build x86_64
  lipo -create build/VibeToken-arm64 build/VibeToken-x86_64 -output "$APP/Contents/MacOS/VibeToken"
  codesign --force --sign - "$APP" >/dev/null
  (cd build && rm -f VibeToken.zip && ditto -c -k --keepParent VibeToken.app VibeToken.zip)
  echo "Release: build/VibeToken.zip"
  exit 0
fi

build "$(uname -m)"
mv "build/VibeToken-$(uname -m)" "$APP/Contents/MacOS/VibeToken"
codesign --force --sign - "$APP" >/dev/null

mkdir -p "$HOME/Applications"
pkill -x VibeToken 2>/dev/null && sleep 0.5 || true
rm -rf "$HOME/Applications/VibeToken.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed: $HOME/Applications/VibeToken.app"

[[ "${1:-}" == "--no-open" ]] || open "$HOME/Applications/VibeToken.app"

#!/bin/bash
# Builds build/SpinnerKey.app. Pass --install to copy it to /Applications.
# Set SIGN_IDENTITY to a "Developer ID Application: …" identity to sign properly;
# the default is an ad-hoc signature, which is fine for use on your own Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SpinnerKey"
APP="build/SpinnerKey.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpinnerKey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/SpinnerKey.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/SpinnerKey.app"
fi

#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
APP="$PWD/Scan Cleaner.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(uname -m)
mkdir -p dist
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/scan-cleaner-release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Scan Cleaner.app"
cp README.md "$STAGING/README.md"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Scan Cleaner" -srcfolder "$STAGING" -ov -format UDZO "dist/Scan-Cleaner-${VERSION}-macOS-${ARCH}.dmg"
(cd dist && shasum -a 256 "Scan-Cleaner-${VERSION}-macOS-${ARCH}.dmg" > "Scan-Cleaner-${VERSION}-macOS-${ARCH}.dmg.sha256")
echo "Packaged dist/Scan-Cleaner-${VERSION}-macOS-${ARCH}.dmg"

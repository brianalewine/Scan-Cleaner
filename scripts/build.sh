#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/Scan Tidy.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScanTidy "$APP/Contents/MacOS/ScanTidy"
swift scripts/make-icon.swift "$PWD/Assets" "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp Assets/AppIcon.pdf "$APP/Contents/Resources/AppIcon.pdf"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScanTidy</string>
<key>CFBundleIdentifier</key><string>local.scantidy.app</string>
<key>CFBundleName</key><string>Scan Tidy</string>
<key>CFBundleDisplayName</key><string>Scan Tidy</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
touch "$APP"
echo "Built $APP"

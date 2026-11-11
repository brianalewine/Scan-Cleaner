#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/Scan Cleaner.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Remove obsolete executables from previous builds of this bundle.
find "$APP/Contents/MacOS" -type f ! -name ScanCleaner -delete
cp .build/release/ScanCleaner "$APP/Contents/MacOS/ScanCleaner"
xcrun actool "$PWD/Assets/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$PWD/.build/icon-info.plist" \
    --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
    --development-region en --target-device mac --minimum-deployment-target 14.0 --platform macosx
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScanCleaner</string>
<key>CFBundleIdentifier</key><string>local.scancleaner.app</string>
<key>CFBundleName</key><string>Scan Cleaner</string>
<key>CFBundleDisplayName</key><string>Scan Cleaner</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
touch "$APP"
echo "Built $APP"

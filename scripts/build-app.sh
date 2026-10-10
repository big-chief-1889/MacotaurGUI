#!/bin/zsh
# Build Macotaur.app (release) into build/.
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftUI's macros need Xcode; the Command Line Tools alone can't build the app.
if [[ -z ${DEVELOPER_DIR:-} && $(xcode-select -p 2>/dev/null) == /Library/Developer/CommandLineTools && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product MacotaurApp

APP=build/Macotaur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacotaurApp "$APP/Contents/MacOS/Macotaur"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The app includes the miner, so it carries both licenses.
cp LICENSE ../Macotaur/THIRD_PARTY_NOTICES "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Macotaur</string>
    <key>CFBundleDisplayName</key><string>Macotaur</string>
    <key>CFBundleIdentifier</key><string>app.macotaur.miner</string>
    <key>CFBundleExecutable</key><string>Macotaur</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

#!/bin/zsh
# Build Macotaur.app and zip it for a release: build/Macotaur-<version>.zip.
# The app is ad-hoc signed, not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Macotaur.app/Contents/Info.plist)
ZIP="build/Macotaur-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent build/Macotaur.app "$ZIP"
echo "Packaged $ZIP"

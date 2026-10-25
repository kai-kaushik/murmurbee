#!/bin/zsh
# Package build.noindex/MurmurBee.app into a drag-to-Applications DMG: build.noindex/MurmurBee-<version>.dmg
# Signed with the local "Local Flow Dev" certificate, so it installs on this Mac without warnings.
# Other Macs will see Gatekeeper's "unidentified developer" warning until it's signed with an Apple
# Developer ID and notarized (needs an Apple Developer account).
set -euo pipefail
cd "${0:A:h}"

APP="build.noindex/MurmurBee.app"
[[ -d "$APP" ]] || { echo "Run ./build.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=build.noindex/dmg-stage
DMG="build.noindex/MurmurBee-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MurmurBee" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

IDENTITY=$(security find-identity -p codesigning | awk '/"Local Flow Dev"/{print $2; exit}')
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG"
echo "DMG: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"

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
DMG="build.noindex/MurmurBee-$VERSION.dmg"

rm -f "$DMG"
# Window layout and background via dmgbuild (writes the Finder layout directly; no Finder scripting).
uv run --quiet --no-project --with dmgbuild dmgbuild -s dmg_settings.py \
  -D app="$APP" -D icon=Resources/brand/AppIcon.icns -D background=Resources/dmg/background.tiff \
  "MurmurBee" "$DMG"

IDENTITY=$(security find-identity -p codesigning | awk '/"Local Flow Dev"/{print $2; exit}')
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG"
echo "DMG: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"

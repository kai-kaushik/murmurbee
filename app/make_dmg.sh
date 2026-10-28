#!/bin/zsh
# Package build.noindex/MurmurBee.app into a drag-to-Applications DMG: build.noindex/MurmurBee-<version>.dmg
# With a Developer ID certificate it is signed, notarized by Apple (keychain profile "murmurbee", see
# `xcrun notarytool store-credentials`) and stapled, so it opens on any Mac without warnings.
# Without one it falls back to the local "Local Flow Dev" certificate.
set -euo pipefail
cd "${0:A:h}"

APP="${MB_APP:-build.noindex/MurmurBee.app}"
[[ -d "$APP" ]] || { echo "Run ./build.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="${APP:h}/MurmurBee-$VERSION.dmg"

DEVID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n "$DEVID" ]]; then
  # Notarize and staple the app itself first, so it carries Apple's approval even when copied out of the DMG and
  # opened offline.
  ZIP="${APP:h}/MurmurBee-app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile murmurbee --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

rm -f "$DMG"
# Window layout and background via dmgbuild (writes the Finder layout directly; no Finder scripting).
uv run --quiet --no-project --with dmgbuild==1.6.7 dmgbuild -s dmg_settings.py \
  -D app="$APP" -D icon=Resources/brand/AppIcon.icns -D background=Resources/dmg/background.tiff \
  "MurmurBee" "$DMG"

if [[ -n "$DEVID" ]]; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile murmurbee --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  IDENTITY=$(security find-identity -p codesigning | awk '/"Local Flow Dev"/{print $2; exit}')
  [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG"
fi
echo "DMG: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"

# Sparkle: sign the DMG with the update key (kept in the login keychain) and write the update feed for the site.
SIGN=build.noindex/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
if [[ -x "$SIGN" ]]; then
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
  SIG=$("$SIGN" "$DMG")   # sparkle:edSignature="..." length="..."
  python3 make_appcast.py "$VERSION" "$BUILD" "$SIG" > ../site/appcast.xml
  echo "Appcast: site/appcast.xml ($VERSION, build $BUILD)"
fi

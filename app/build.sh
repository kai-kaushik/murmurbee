#!/bin/zsh
# Build MurmurBee.app (Release) into app/build/.
# xcodebuild, not `swift build`, because MLX's Metal shaders only compile through Xcode's toolchain.
set -euo pipefail
cd "${0:A:h}"

DD=build.noindex/dd  # .noindex keeps Spotlight from listing a second copy of the app
APP="${MB_APP:-build.noindex/MurmurBee.app}"  # MB_APP: build elsewhere (e.g. while experiments use this copy)

xcodebuild -scheme MurmurBee -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DD" -skipMacroValidation -skipPackagePluginValidation build -quiet

PRODUCTS="$DD/Build/Products/Release"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/MurmurBee" "$APP/Contents/MacOS/MurmurBee"
# SwiftPM resource bundles (MLX metallib, tokenizer data, ...) go in Resources.
for b in "$PRODUCTS"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
# Interface sounds (scripts/make_sounds.py)
cp -R Resources/sounds "$APP/Contents/Resources/sounds"
# Brand: app icon, menu-bar bee, window bee, Sora font (scripts/make_icons.swift)
cp -R Resources/brand "$APP/Contents/Resources/brand"
cp Resources/brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/fonts "$APP/Contents/Resources/fonts"
# Licences and credits for the models and open-source components (Apache 2.0 requires shipping the texts).
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/ThirdPartyNotices.txt"
# Sparkle (auto-updates) lives in Contents/Frameworks; ditto keeps the framework's symlinks intact.
mkdir -p "$APP/Contents/Frameworks"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MurmurBee" 2>/dev/null || true
# MLX finds its shaders in Resources/mlx-swift_Cmlx.bundle (default.metallib). No copy next to the binary:
# anything in Contents/MacOS must be code, and a loose .metallib there breaks Developer ID signing.

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.murmurbee.app</string>
  <key>CFBundleName</key><string>MurmurBee</string>
  <key>CFBundleExecutable</key><string>MurmurBee</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.8</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>SUFeedURL</key><string>https://murmurbee.com/appcast.xml</string>
  <key>SUPublicEDKey</key><string>RefVcQGGvefHH5JAxg5BFPRGZD1Z4A4YHtBG03PEKfA=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>NSMicrophoneUsageDescription</key><string>MurmurBee listens while you hold the dictation key and transcribes on this Mac.</string>
</dict></plist>
PLIST

# Developer ID with the hardened runtime when available (needed for notarization); otherwise the stable
# self-signed identity, so macOS permissions survive local rebuilds; otherwise ad-hoc.
DEVID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n "$DEVID" ]]; then
  # Sign Sparkle inside-out (its XPC services and helpers first), as Sparkle's docs require for Developer ID.
  SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$SPK/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$DEVID" "$SPK/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$SPK/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$SPK/Updater.app"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --entitlements MurmurBee.entitlements --sign "$DEVID" "$APP"
else
  IDENTITY=$(security find-identity -p codesigning | awk '/"Local Flow Dev"/{print $2; exit}')
  codesign --force --deep --sign "${IDENTITY:--}" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built: $PWD/$APP"
[[ -n "${SKIP_INSTALL:-}" ]] && exit 0

# Install where System Settings' "+" picker looks by default.
rm -rf "/Applications/MurmurBee.app" "/Applications/Local Flow.app"  # (old name)
cp -R "$APP" /Applications/
echo "Installed: /Applications/MurmurBee.app"

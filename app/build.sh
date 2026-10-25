#!/bin/zsh
# Build MurmurBee.app (Release) into app/build/.
# xcodebuild, not `swift build`, because MLX's Metal shaders only compile through Xcode's toolchain.
set -euo pipefail
cd "${0:A:h}"

DD=build.noindex/dd  # .noindex keeps Spotlight from listing a second copy of the app
APP="build.noindex/MurmurBee.app"
MODEL_SRC=../models/qwen35-0.8b-kai-v1
MODEL_DST="$HOME/Library/Application Support/MurmurBee/models/qwen35-0.8b-kai-v1"

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
# Seed for ~/Library/Application Support/MurmurBee/dictionary.txt (first run only), from the Wispr dictionary.
[[ -f ../data/vocab.txt ]] && cp ../data/vocab.txt "$APP/Contents/Resources/dictionary-seed.txt"
# MLX also looks for its metallib next to the binary.
METALLIB=$(find "$PRODUCTS" -name "default.metallib" -path "*mlx*" | head -1)
[[ -n "$METALLIB" ]] && cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.kaigen.murmurbee</string>
  <key>CFBundleName</key><string>MurmurBee</string>
  <key>CFBundleExecutable</key><string>MurmurBee</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>MurmurBee listens while you hold the dictation key and transcribes on this Mac.</string>
</dict></plist>
PLIST

mkdir -p "${MODEL_DST:h}"
[[ -d "$MODEL_DST" ]] || cp -R "$MODEL_SRC" "$MODEL_DST"

# Stable self-signed identity, so macOS permissions survive rebuilds (falls back to ad-hoc).
IDENTITY=$(security find-identity -p codesigning | awk '/"Local Flow Dev"/{print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built: $PWD/$APP"

# Install where System Settings' "+" picker looks by default.
rm -rf "/Applications/MurmurBee.app" "/Applications/Local Flow.app"  # (old name)
cp -R "$APP" /Applications/
echo "Installed: /Applications/MurmurBee.app"

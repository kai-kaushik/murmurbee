#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build.noindex
swiftc -swift-version 6 -target arm64-apple-macos15.0 \
  Sources/MurmurBee/CaptureHealth.swift Sources/MurmurBee/AudioDevices.swift \
  Tests/CaptureHealthTests.swift -o build.noindex/capture-health-tests
build.noindex/capture-health-tests
if [[ "${1:-}" == "--hardware" ]]; then
  PROBE="build.noindex/CaptureProbe.app"
  mkdir -p "$PROBE/Contents/MacOS"
  cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.murmurbee.capture-probe</string>
<key>CFBundleExecutable</key><string>CaptureProbe</string>
<key>CFBundleName</key><string>MurmurBee Capture Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSMicrophoneUsageDescription</key><string>Checks microphone startup locally. No audio is saved.</string>
</dict></plist>
PLIST
  swiftc -swift-version 6 -target arm64-apple-macos15.0 \
    Sources/MurmurBee/{CaptureHealth,AudioDevices,Recorder}.swift Tests/CaptureStartupProbe.swift \
    -o "$PROBE/Contents/MacOS/CaptureProbe"
  codesign --force --sign - "$PROBE"
  echo "Hardware probe ready: $PWD/$PROBE (open it to run; microphone permission required)"
fi

#!/bin/zsh
# Wraps the Debug build (xcodebuild -configuration Debug, same derived data as build.sh) in a bundle the way build.sh
# does, without installing it, so its developer test modes (--meeting-test, --notes-test, ...) can run.
set -euo pipefail
cd "${0:A:h}"
P=build.noindex/dd/Build/Products/Debug APP=build.noindex/MurmurBee-debug.app
[[ -x $P/MurmurBee ]] || { echo "no Debug build in $P"; exit 1; }
rm -rf $APP; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp $P/MurmurBee $APP/Contents/MacOS/MurmurBee
for b in $P/*.bundle(N); do cp -R $b $APP/Contents/Resources/; done
cp -R Resources/sounds Resources/brand Resources/fonts $APP/Contents/Resources/
ditto $(find $P -maxdepth 3 -name Sparkle.framework | head -1) $APP/Contents/Frameworks/Sparkle.framework
install_name_tool -add_rpath "@executable_path/../Frameworks" $APP/Contents/MacOS/MurmurBee 2>/dev/null || true
sed -n "/^cat > .*Info.plist/,/^PLIST/p" build.sh | sed '1d;$d' > $APP/Contents/Info.plist
codesign --force --deep --sign - $APP 2>/dev/null
echo $PWD/$APP

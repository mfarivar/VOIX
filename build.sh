#!/bin/zsh
# Builds build/VOIX.app (universal: Apple silicon + Intel).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/VOIX.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon
[ -f Resources/icon_1024.png ] || swift Tools/make_icon.swift Resources/icon_1024.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VOIX</string>
  <key>CFBundleDisplayName</key><string>VOIX</string>
  <key>CFBundleIdentifier</key><string>io.github.mfarivar.voix</string>
  <key>CFBundleExecutable</key><string>VOIX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Masoud Farivar. MIT License.</string>
  <key>NSMicrophoneUsageDescription</key><string>VOIX records your voice while you hold the push-to-talk key.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>VOIX uses Apple's on-device speech recognition to transcribe what you say.</string>
</dict></plist>
EOF

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 Sources/*.swift -o build/VOIX-$arch \
    -framework AppKit -framework AVFoundation -framework Speech -framework SwiftUI
done
lipo -create build/VOIX-arm64 build/VOIX-x86_64 -output "$APP/Contents/MacOS/VOIX"
rm build/VOIX-arm64 build/VOIX-x86_64

# Signing, best first:
#   1. Developer ID Application (release builds; hardened runtime, notarizable)
#   2. "VOIX Local Signing" (see Tools/make_cert.sh; keeps macOS permissions across local rebuilds)
#   3. ad-hoc
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$DEV_ID" ]; then
  codesign --force --options runtime --timestamp --entitlements Packaging/VOIX.entitlements --sign "$DEV_ID" "$APP"
  echo "Signed with $DEV_ID"
elif security find-identity -p codesigning 2>/dev/null | grep -q "VOIX Local Signing"; then
  codesign --force --sign "VOIX Local Signing" "$APP"
else
  echo "note: no signing certificate found; signing ad-hoc (macOS permissions reset on each rebuild)"
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"

#!/bin/zsh
set -e
cd "$(dirname "$0")"
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
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VOIX</string>
  <key>CFBundleIdentifier</key><string>local.voix</string>
  <key>CFBundleExecutable</key><string>VOIX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>VOIX records your voice while you hold the push-to-talk key.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>VOIX transcribes your voice on-device.</string>
</dict></plist>
EOF
# Universal binary: Apple silicon + Intel.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 Sources/main.swift -o build/VOIX-$arch \
    -framework AppKit -framework AVFoundation -framework Speech -framework SwiftUI
done
lipo -create build/VOIX-arm64 build/VOIX-x86_64 -output "$APP/Contents/MacOS/VOIX"
rm build/VOIX-arm64 build/VOIX-x86_64
# Stable identity keeps macOS permissions across rebuilds (see Tools/make_cert.sh); ad-hoc otherwise.
if security find-identity -p codesigning | grep -q "VOIX Local Signing"; then
  codesign --force --sign "VOIX Local Signing" "$APP"
else
  echo "warning: no 'VOIX Local Signing' cert, signing ad-hoc (permissions reset on each rebuild)"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

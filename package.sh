#!/bin/zsh
# Builds VOIX and wraps it in a drag-to-install disk image: build/VOIX-<version>.dmg (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

VERSION=$(cat VERSION)
DMG=build/VOIX-$VERSION.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
cp -R build/VOIX.app "$STAGE/"
cp "Packaging/Install Whisper.command" Packaging/README.txt "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VOIX $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Created $DMG"

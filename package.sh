#!/bin/zsh
# Builds VOIX and wraps it in a single drag-to-install disk image: build/VOIX.dmg
set -e
cd "$(dirname "$0")"
./build.sh
STAGE=build/dmg
rm -rf "$STAGE" build/VOIX.dmg
mkdir -p "$STAGE"
cp -R build/VOIX.app "$STAGE/"
cp "Packaging/Install Whisper.command" Packaging/README.txt "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname VOIX -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/VOIX.dmg >/dev/null
rm -rf "$STAGE"
echo "Created build/VOIX.dmg"

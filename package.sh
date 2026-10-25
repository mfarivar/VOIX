#!/bin/zsh
# Builds VOIX and wraps it in a drag-to-install disk image: build/VOIX-<version>.dmg (+ .sha256)
#
# With a "Developer ID Application" certificate in the keychain and notarization
# credentials stored once via
#   xcrun notarytool store-credentials VOIX-notary --apple-id <apple-id> --team-id <team-id>
# the app and disk image are also notarized and stapled, so they open without warnings.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

VERSION=$(cat VERSION)
DMG=build/VOIX-$VERSION.dmg
PROFILE=${NOTARY_PROFILE:-VOIX-notary}
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
NOTARIZE=false
if [ -n "$DEV_ID" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  NOTARIZE=true
fi

if $NOTARIZE; then
  echo "Notarizing VOIX.app…"
  ditto -c -k --keepParent build/VOIX.app build/VOIX.zip
  xcrun notarytool submit build/VOIX.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple build/VOIX.app
  rm build/VOIX.zip
fi

STAGE=build/dmg
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
cp -R build/VOIX.app "$STAGE/"
cp "Packaging/Install Whisper.command" Packaging/README.txt "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VOIX $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if $NOTARIZE; then
  echo "Notarizing $DMG…"
  codesign --force --timestamp --sign "$DEV_ID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "note: not notarized (needs a Developer ID Application certificate and the '$PROFILE' notarytool profile)"
fi

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Created $DMG"

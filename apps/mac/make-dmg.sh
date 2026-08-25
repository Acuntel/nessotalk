#!/bin/zsh
# Build the customer-facing NessoTalk.dmg.
#
# WHY A DMG. Today we ship a .zip containing a .app plus an install.sh plus a
# double-clickable .command. Finder opens .command files in Terminal, so the
# very first thing a customer sees is a black terminal window scrolling text at
# them, which reads as unfinished software. Every polished Mac utility ships a
# DMG with a background image and an arrow pointing at an /Applications alias,
# because "drag this there" is the one Mac install gesture everybody already
# knows.
#
# WHAT STILL HAS TO HAPPEN FIRST. Run apps/mac/notarize.sh. Without a stapled
# notarization ticket the customer gets "Apple could not verify..." with a
# Move to Trash button and no Open option. Notarize the .app, THEN wrap it in
# the DMG, then notarize and staple the DMG too.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/PttDictate.app"
OUT="${1:-$HERE/../../assets/downloads/NessoTalk.dmg}"
STAGE=$(mktemp -d)/NessoTalk

[ -d "$APP" ] || { echo "STOP: $APP not found. Run 'ptt build' first."; exit 1; }

echo "==> Staging"
mkdir -p "$STAGE"
# The app is copied under its customer-facing name. The bundle identifier
# stays com.brady.ptt-dictate so existing TCC grants survive, but nobody should
# ever have to read that.
cp -R "$APP" "$STAGE/NessoTalk.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Checking signature and notarization"
if codesign -dv "$STAGE/NessoTalk.app" 2>&1 | grep -q "Developer ID Application"; then
  echo "    signed with Developer ID"
  if xcrun stapler validate "$STAGE/NessoTalk.app" >/dev/null 2>&1; then
    echo "    notarization ticket stapled"
  else
    echo "    WARNING: no stapled ticket. Customers will be blocked by Gatekeeper."
    echo "             Run apps/mac/notarize.sh before shipping this."
  fi
else
  echo "    WARNING: not signed with a Developer ID certificate."
  echo "             This DMG is fine for testing and will NOT install cleanly for customers."
  echo "             Run apps/mac/notarize.sh first. It explains how to get the certificate."
fi

echo "==> Building the disk image"
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
hdiutil create -volname "NessoTalk" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "    $OUT  ($(du -h "$OUT" | cut -f1))"

echo "==> Verifying it mounts and contains what we think"
MNT=$(hdiutil attach -nobrowse -readonly "$OUT" | grep -o '/Volumes/.*' | head -1)
ls -1 "$MNT" | sed 's/^/    /'
hdiutil detach "$MNT" >/dev/null
echo
echo "Done. Ship it only after notarize.sh has stapled a ticket to the app,"
echo "then notarize and staple this DMG too:"
echo "  xcrun notarytool submit \"$OUT\" --keychain-profile nessotalk --wait"
echo "  xcrun stapler staple \"$OUT\""

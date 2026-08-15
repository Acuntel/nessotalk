#!/bin/zsh
# Sign, notarize, and staple NessoTalk for distribution outside the App Store.
#
# WHY THIS EXISTS: the app currently ships signed with an "Apple Development"
# certificate, which is a development identity, not a distribution one. Gatekeeper
# rejects it. A customer who downloads the zip gets a dialog whose primary button
# is "Move to Trash", and since macOS 15 the right-click-to-Open workaround is
# gone. This script is the fix.
#
# PREREQUISITES, both one-time and both yours to do:
#
#   1. A "Developer ID Application" certificate in your keychain.
#      You ALREADY have a paid Apple Developer membership: the keychain holds
#      "Apple Distribution: BRADY NATHAN SCHWARTZ (PY94U6N48R)", which only
#      exists with one. But Apple Distribution is for the App Store. Direct
#      download needs Developer ID Application, which is free to create at
#      developer.apple.com/account/resources/certificates, or in Xcode under
#      Settings, Accounts, Manage Certificates, the plus button.
#
#   2. Notarization credentials stored once:
#        xcrun notarytool store-credentials nessotalk \
#          --apple-id <your apple id> \
#          --team-id PY94U6N48R \
#          --password <app-specific password from appleid.apple.com>
#
# Then just run this script. It refuses to do anything destructive if either
# prerequisite is missing.
set -e

APP="${1:-$(cd "$(dirname "$0")" && pwd)/PttDictate.app}"
PROFILE="${NOTARY_PROFILE:-nessotalk}"
ENTITLEMENTS="$(cd "$(dirname "$0")" && pwd)/PttDictate.entitlements"

echo "==> Looking for a Developer ID Application certificate"
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | awk '{print $2}')
if [ -z "$IDENTITY" ]; then
  echo "STOP: no 'Developer ID Application' certificate found."
  echo
  echo "You have a paid membership already. Create the certificate at:"
  echo "  https://developer.apple.com/account/resources/certificates"
  echo "or in Xcode: Settings, Accounts, Manage Certificates, plus, Developer ID Application."
  echo
  echo "What you have now:"
  security find-identity -v -p codesigning | sed 's/^/  /'
  exit 1
fi
echo "    using $IDENTITY"

echo "==> Signing with the hardened runtime"
# --options runtime is what notarization requires. The entitlements file carries
# the exceptions the app genuinely needs, chiefly library validation, because it
# shells out to Homebrew's whisper-cli and ffmpeg.
codesign --force --deep --timestamp \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Zipping for submission"
TMP=$(mktemp -d)
ditto -c -k --keepParent "$APP" "$TMP/PttDictate.zip"

echo "==> Submitting to Apple (this is an automated scan, usually a few minutes)"
if ! xcrun notarytool submit "$TMP/PttDictate.zip" \
     --keychain-profile "$PROFILE" --wait; then
  echo
  echo "STOP: notarization failed. If the error is about credentials, run:"
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id PY94U6N48R --password <app-specific password>"
  echo "If it is about the binary, get the detail with:"
  echo "  xcrun notarytool log <submission-id> --keychain-profile $PROFILE"
  exit 1
fi

echo "==> Stapling the ticket so it works offline and on first launch"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> The verdict that actually matters"
# spctl is the Gatekeeper assessment itself. A notarytool success message is not
# proof; this is. Accepted here means a downloaded copy opens without a dialog.
spctl -a -vvv -t exec "$APP" || true

echo
echo "Done. Now rebuild both zips and re-run the quarantine test:"
echo "  ditto -c -k --norsrc --keepParent <staged dir> assets/downloads/nessotalk-mac-beta.zip"
echo "  xattr -w com.apple.quarantine '0083;00000000;Safari;' <extracted app>"
echo "  <extracted app>/Contents/MacOS/ptt-dictate --local-mode normal   # must NOT hang"
echo
echo "Also delete the 'System Settings, Open Anyway' step from components/Walkthrough.tsx,"
echo "which becomes wrong once this is stapled."

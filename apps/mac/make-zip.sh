#!/bin/zsh
# Build the customer-facing yappertalk-mac-beta.zip.
#
# WHY THIS EXISTS: the zip used to be assembled by hand, so it drifted. The
# copy on the website was built on 29 August and still unpacked to a folder
# called nessotalk-mac containing an "Install NessoTalk.command" and an
# installer several fixes out of date, while the repo had moved on. A download
# nobody can rebuild in one command is a download that is always stale.
#
# This does NOT sign or notarize. Run notarize.sh first if you want the app to
# open without Gatekeeper stopping the customer; the check at the bottom tells
# you where you stand.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/PttDictate.app"
OUT="${1:-$HERE/../../assets/downloads/yappertalk-mac-beta.zip}"
STAGE="$(mktemp -d)/yappertalk-mac"

[ -d "$APP" ] || { echo "STOP: $APP not found. Run 'ptt build' first."; exit 1; }

# `ptt build` compiles into ~/.dictation, NOT into this bundle, so it is easy to
# package a binary older than the source and never notice. Refuse instead.
BIN="$APP/Contents/MacOS/ptt-dictate"
if [ -f "$BIN" ] && [ "$HERE/ptt-dictate.swift" -nt "$BIN" ]; then
  cat <<'STALE'
STOP: ptt-dictate.swift is newer than the binary in PttDictate.app, so this
would ship a build that does not contain your latest changes.

  ptt build                                     # compile
  ditto ~/.dictation/PttDictate.app ./PttDictate.app   # bring it back here
  ./notarize.sh                                 # sign for distribution
  ./make-zip.sh                                 # then this

STALE
  exit 1
fi

echo "==> Staging"
mkdir -p "$STAGE"
for f in ptt Info.plist config.example snippets.example install.sh "Install YapperTalk.command"; do
  [ -e "$HERE/$f" ] || { echo "STOP: missing $f"; exit 1; }
  cp -R "$HERE/$f" "$STAGE/"
done
# ditto rather than cp -R for the bundle: it preserves the extended attributes
# the code signature lives in. A plain copy or a plain `zip` can strip them and
# produce a bundle that fails to verify on the customer's machine.
ditto "$APP" "$STAGE/PttDictate.app"
chmod +x "$STAGE/ptt" "$STAGE/install.sh" "$STAGE/Install YapperTalk.command"

echo "==> Packing"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# --keepParent so the zip expands to a folder rather than spraying files into
# Downloads; --sequesterRsrc keeps resource forks intact for the same reason
# ditto is used above.
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"
rm -rf "$(dirname "$STAGE")"

echo "==> Built $OUT ($(du -h "$OUT" | cut -f1))"
echo ""
echo "==> Gatekeeper check"
if spctl -a -vv -t exec "$APP" 2>&1 | grep -q "accepted"; then
  echo "    PASS. This will open without a warning."
else
  cat <<'WARN'
    FAIL. This build is NOT accepted by Gatekeeper, which means the customer
    sees a dialog whose primary button is "Move to Trash", and since macOS 15
    there is no right-click-to-Open workaround.

    Fix: run ./notarize.sh (needs a Developer ID Application certificate),
    then run this script again.

    Ship the zip as it stands only for people you can walk through it.
WARN
fi

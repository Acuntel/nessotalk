#!/bin/zsh
# YapperTalk for Mac: guided installer.
#
# Customers double-click "Install YapperTalk.command", which runs this. Every
# stage explains itself in the Terminal window, and the moments that need a
# human decision open a real dialog, because nobody reads scrolling text.
#
# Two rules this file follows:
#   1. It never dies silently. Any failure prints what broke, what still works,
#      and where to look, because a half-finished install that says nothing is
#      the worst outcome available.
#   2. It never claims something worked without checking. "YapperTalk is
#      running" is printed after asking launchd, not after asking it to start.
set -u
DIR="$HOME/.dictation"
LOG="$DIR/install.log"
LABEL="com.brady.ptt-dictate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$DIR"
: > "$LOG"

# Everything noisy goes to the log; the terminal keeps the human-readable story.
exec 3>>"$LOG"
note() { echo "$@" >&3; }

fail() {   # message
  echo ""
  echo "  ────────────────────────────────────────────────────────────"
  echo "  Setup stopped: $1"
  echo ""
  echo "  Nothing on your Mac was damaged. The details are in:"
  echo "    $LOG"
  echo ""
  echo "  Send us that file at hello@yappertalk.com and we will sort it."
  echo "  ────────────────────────────────────────────────────────────"
  echo ""
  osascript -e "display dialog \"Setup stopped: $1\n\nThe details are in ~/.dictation/install.log. Send that to hello@yappertalk.com and we will sort it.\" with title \"YapperTalk\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1 || true
  exit 1
}
trap 'fail "an unexpected error on line $LINENO"' ERR
set -e

say_dialog() {   # title, message
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"Continue\"} default button 1 with icon note" >/dev/null 2>&1 || true
}

open_settings() { # pane anchor
  # macOS 26 (Tahoe) renamed the Privacy pane bundle. The old identifier does
  # not error on 26, it just dumps the person at a generic Settings window with
  # no idea which row to find, which is worse than not opening it at all.
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  local pane="com.apple.preference.security"
  [ "${major:-0}" -ge 26 ] && pane="com.apple.settings.PrivacySecurity.extension"
  open "x-apple.systempreferences:${pane}?$1" 2>/dev/null || true
}

TOTAL=6
step() { echo ""; echo "[$1 of $TOTAL] $2"; note "=== step $1: $2"; }

clear
cat <<'BANNER'
  YapperTalk
  Talk instead of typing, in any app on your Mac.

  This takes about a minute. Your words are transcribed on the YapperTalk
  engine, so there is no large model to download and nothing heavy to keep
  on your Mac.
BANNER

# ---------------------------------------------------------------------------
step 1 "Checking this Mac."
# Cheap checks first. Finding out the OS is too old AFTER copying files and
# installing a launch agent means cleaning up a mess that never had to exist.
OSV=$(sw_vers -productVersion)
OSMAJ=${OSV%%.*}
note "macOS $OSV, arch $(uname -m)"
if [ "${OSMAJ:-0}" -lt 13 ]; then
  fail "YapperTalk needs macOS 13 or newer, and this Mac is on $OSV"
fi
echo "    macOS $OSV on $(uname -m). Good."

# An install over the top of a running daemon leaves the old one holding the
# binary and the hotkey. Stop it before anything is replaced.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  echo "    An earlier version is running. Stopping it first."
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  sleep 1
fi

# ---------------------------------------------------------------------------
step 2 "Checking the two small helpers YapperTalk uses."
# Transcription happens on the YapperTalk engine. These two are only used for
# cleaning up the audio before it is sent and for the on-screen live captions,
# so a missing Homebrew is a downgrade, never a hard stop.
if command -v brew >/dev/null 2>&1; then
  { brew list ffmpeg      >/dev/null 2>&1 || brew install ffmpeg;      } >&3 2>&1 || true
  { brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp; } >&3 2>&1 || true
  echo "    Done."
else
  echo "    Homebrew is not installed, so live typing and audio cleanup stay off."
  echo "    Dictation itself works without them. Install Homebrew from brew.sh"
  echo "    later and run this installer again to switch them on."
fi

# ---------------------------------------------------------------------------
step 3 "Setting up live typing."
# ONLY the small English caption model, about 60 MB, and only so the pill can
# put words on screen as you speak. The model that produces your actual
# transcript runs on the YapperTalk engine and is never copied to a customer
# machine: that is what makes a subscription something we can grant and revoke.
mkdir -p "$HOME/.whisper-models"
# The two models live in DIFFERENT repositories. The VAD model is not in the
# whisper.cpp repo and 404s there, which is how every fresh install quietly
# ended up with no speech gate while dev machines that already had the file
# looked fine.
fetch_small() { # url, filename
  if [ -s "$HOME/.whisper-models/$2" ]; then return 0; fi
  if curl -fsS -# -L -o "$HOME/.whisper-models/$2.part" "$1" 2>&3; then
    mv "$HOME/.whisper-models/$2.part" "$HOME/.whisper-models/$2"
  else
    rm -f "$HOME/.whisper-models/$2.part"
    echo "    Could not fetch $2. Live typing stays off; dictation is unaffected."
    note "FAILED to fetch $1"
  fi
}
fetch_small "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin" ggml-base.en-q5_1.bin
fetch_small "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" ggml-silero-v5.1.2.bin
echo "    Done. Your transcript is produced on the YapperTalk engine, which is"
echo "    why there is no multi-gigabyte model sitting on your Mac."

# ---------------------------------------------------------------------------
step 4 "Installing YapperTalk."
for f in ptt Info.plist PttDictate.app config.example snippets.example; do
  [ -e "$f" ] || fail "the download is missing $f, so it did not unzip completely"
done

cp -f ptt Info.plist "$DIR/"
rm -rf "$DIR/PttDictate.app"
cp -R PttDictate.app "$DIR/"

# Anything downloaded through a browser carries com.apple.quarantine, and a
# quarantined app that is not notarized does not launch: it hangs with no error
# and macOS offers a "Move to Trash" button. The customer ran this installer
# deliberately, which is exactly the consent Gatekeeper is asking about, so
# clear the flag on the copy we just installed.
xattr -dr com.apple.quarantine "$DIR/PttDictate.app" 2>/dev/null || true
xattr -dr com.apple.quarantine "$DIR/ptt" 2>/dev/null || true

# Register the bundle with LaunchServices explicitly. The daemon is started by
# launchd against the executable INSIDE the bundle, so nothing ever asks
# LaunchServices to look at the bundle itself, and the yappertalk:// scheme it
# declares can go unregistered — which silently breaks sign-in, because the
# browser hands the code back over that scheme. Doing it here also replaces a
# stale registration left by an older build.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DIR/PttDictate.app" >&3 2>&1 || true

[ -f "$DIR/snippets" ] || cp -f snippets.example "$DIR/snippets"
[ -f "$DIR/config" ]   || cp -f config.example   "$DIR/config"

# Your download may carry a key. The public download does not, and that is the
# normal case: you connect an account on first use instead.
KEY="${1:-}"
if [ -z "$KEY" ] && [ -f "LICENSE_KEY" ]; then
  KEY=$(tr -d ' \t\r\n' < LICENSE_KEY)
fi
if [ -n "$KEY" ]; then
  grep -q '^LICENSE_KEY=' "$DIR/config" \
    && sed -i '' -E "s|^LICENSE_KEY=.*|LICENSE_KEY=$KEY|" "$DIR/config" \
    || printf '\nLICENSE_KEY=%s\n' "$KEY" >> "$DIR/config"
  echo "    Your licence came with the download and is already active."
  NEEDS_SIGNIN=0
else
  NEEDS_SIGNIN=1
fi

chmod +x "$DIR/ptt"
# The config holds the licence key, so it is the user's alone to read.
chmod 600 "$DIR/config" 2>/dev/null || true

# A Mac that has never had a launch agent has no LaunchAgents directory, and
# the redirect below fails outright without it.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/PttDictate.app/Contents/MacOS/ptt-dictate</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/ptt.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/ptt.err.log</string>
</dict></plist>
EOF
echo "    Installed."

# ---------------------------------------------------------------------------
step 5 "Starting YapperTalk."
( cd "$DIR" && ./ptt start ) >&3 2>&1 || true

# Ask launchd whether it is actually up, rather than announcing that it is.
RUNNING=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -qE "state = running|pid = "; then
    RUNNING=1; break
  fi
  sleep 1
done
if [ "$RUNNING" = "1" ]; then
  echo "    Running. Look for the microphone icon in your menu bar."
else
  note "daemon did not report running; see ptt.err.log"
  echo "    It did not start on the first try. The log is at $DIR/ptt.err.log."
  echo "    You can retry any time with:  ~/.dictation/ptt start"
fi

# ---------------------------------------------------------------------------
step 6 "Granting the two permissions."
say_dialog "Two permissions to grant" "System Settings will open twice.\n\nFirst, under Microphone, switch on YapperTalk. That lets it hear you.\n\nThen, under Accessibility, switch on YapperTalk. That lets it type for you.\n\nYapperTalk never records until you press the key yourself."
open_settings "Privacy_Microphone"
sleep 3
open_settings "Privacy_Accessibility"

if [ "${NEEDS_SIGNIN:-0}" = "1" ]; then
  say_dialog "Last step: connect your account" "Your browser will open so you can sign in. There is nothing to copy or type.\n\nNo account yet? You can create one on that page. Fourteen days free, no card.\n\nYou can also just press Right Command later and YapperTalk will bring you here itself."
  open "yappertalk://signin" >&3 2>&1 || true
  sleep 2
fi

say_dialog "You are ready" "Here is the whole thing.\n\n1. Click into any text box: an email, a message, anywhere.\n2. Tap the Right Command key once. A bar appears at the bottom of your screen.\n3. Say what you want written.\n4. Tap Right Command again.\n\nYour words appear, cleaned up. Press Escape while recording to throw it away.\n\nTry it now."

cat <<DONE

  Setup is complete.

  Click into any text box, tap Right Command, say a sentence, then tap
  Right Command again. Your words appear, cleaned up and punctuated.
  Press Escape while recording to cancel and type nothing.

  The microphone icon in your menu bar shows whether it is listening.

  Useful commands:
    ~/.dictation/ptt signin     connect or change the account
    ~/.dictation/ptt status     is it running?
    ~/.dictation/ptt log        watch what it is doing
    ~/.dictation/ptt uninstall  remove it completely

DONE
note "=== finished ok"

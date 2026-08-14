#!/bin/zsh
# NessoTalk for Mac: guided installer.
#
# Customers double-click "Install NessoTalk.command", which runs this. Every
# stage explains itself in the Terminal window and the moments that need a
# human decision open a real dialog, because nobody reads scrolling text.
set -e
DIR="$HOME/.dictation"

# Your download already carries your key, so there is nothing to type. Passing
# one as an argument still works if you ever need to swap it.
KEY="$1"
if [ -z "$KEY" ] && [ -f "LICENSE_KEY" ]; then
  KEY=$(tr -d ' \t\r\n' < LICENSE_KEY)
fi

say_dialog() {   # title, message
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"Continue\"} default button 1 with icon note" >/dev/null 2>&1 || true
}
open_settings() { # pane anchor
  open "x-apple.systempreferences:com.apple.preference.security?$1" 2>/dev/null || true
}
step() { echo ""; echo "[$1 of 5] $2"; }

clear
cat <<'BANNER'
  NessoTalk
  Talk instead of typing, in any app on your Mac.

  This installer takes about a minute. Your words are transcribed on the
  NessoTalk engine, so there is no large model to download and nothing
  heavy to keep on your Mac.
BANNER

say_dialog "NessoTalk Setup" "Welcome. This takes about a minute.\n\nAt the end your Mac will ask for two permissions. Both are required: one lets NessoTalk hear you, the other lets it type for you.\n\nClick Continue to begin."

step 1 "Checking the two small helpers NessoTalk uses."
# Transcription happens on the NessoTalk engine. These two are only used for
# cleaning up the audio before it is sent and for the on-screen live captions,
# so a missing Homebrew is a downgrade, never a hard stop.
if command -v brew >/dev/null; then
  brew list ffmpeg      >/dev/null 2>&1 || brew install ffmpeg      || true
  brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp || true
  echo "    Done."
else
  echo "    Homebrew is not installed, so live captions and audio cleanup will"
  echo "    be switched off. Dictation itself works without them. You can install"
  echo "    Homebrew from brew.sh later and re-run this installer to turn them on."
fi

step 2 "Setting up live captions."
# ONLY the small English caption model, about 60 MB, and only so the pill can
# show words as you speak. The model that produces your actual transcript runs
# on the NessoTalk engine and is never copied to a customer machine: that is
# what makes a subscription something we can grant and take away.
mkdir -p "$HOME/.whisper-models"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
fetch_small() { # filename
  [ -s "$HOME/.whisper-models/$1" ] && return 0
  curl -fsS -# -L -o "$HOME/.whisper-models/$1.part" "$BASE/$1" \
    && mv "$HOME/.whisper-models/$1.part" "$HOME/.whisper-models/$1" \
    || { rm -f "$HOME/.whisper-models/$1.part"; echo "    Could not fetch $1. Live captions will stay off; dictation is unaffected."; }
}
fetch_small ggml-base.en-q5_1.bin
fetch_small ggml-silero-v5.1.2.bin
echo "    Done. Your transcript is produced on the NessoTalk engine, which is"
echo "    why there is no multi-gigabyte model sitting on your Mac."

step 3 "Installing NessoTalk and activating your license."
mkdir -p "$DIR"
cp -f ptt Info.plist "$DIR/"
rm -rf "$DIR/PttDictate.app"
cp -R PttDictate.app "$DIR/"
# Anything downloaded through a browser carries com.apple.quarantine, and a
# quarantined app that is not notarized does not launch: it hangs with no error
# and macOS offers the customer a "Move to Trash" button. The customer ran this
# installer deliberately, which is exactly the consent Gatekeeper is asking about,
# so clear the flag on the copy we just installed.
xattr -dr com.apple.quarantine "$DIR/PttDictate.app" 2>/dev/null || true
xattr -dr com.apple.quarantine "$DIR/ptt" 2>/dev/null || true
[ -f "$DIR/snippets" ] || cp -f snippets.example "$DIR/snippets"
[ -f "$DIR/config" ] || cp -f config.example "$DIR/config"
if [ -n "$KEY" ]; then
  grep -q '^LICENSE_KEY=' "$DIR/config" \
    && sed -i '' -E "s|^LICENSE_KEY=.*|LICENSE_KEY=$KEY|" "$DIR/config" \
    || printf '\nLICENSE_KEY=%s\n' "$KEY" >> "$DIR/config"
  echo "    Your license was found in the download and activated automatically."
else
  echo "    No license key in this folder. Add yours from Settings after setup."
  say_dialog "One thing left: your key" "NessoTalk is installing now, and it needs a license key before it can record. Getting one is free and takes about a minute.\n\n1. Go to nesso.tech and create your account. Fourteen days free, no card.\n2. Copy the license key shown on your dashboard.\n3. Open NessoTalk from the menu bar, choose Settings, paste the key into \\\"Your license key\\\", and click Save.\n\nThat is it. You can also grab a copy from your dashboard with the key already inside."
fi
chmod +x "$DIR/ptt"
# The config holds the license key, so it is the user's alone to read. The daemon
# already writes its log and history 0600; the config had been left 0644.
chmod 600 "$DIR/config" 2>/dev/null || true

PLIST="$HOME/Library/LaunchAgents/com.brady.ptt-dictate.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.brady.ptt-dictate</string>
  <key>ProgramArguments</key><array><string>$DIR/PttDictate.app/Contents/MacOS/ptt-dictate</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/ptt.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/ptt.err.log</string>
</dict></plist>
EOF

step 4 "Starting NessoTalk."
cd "$DIR" && ./ptt start
echo "    NessoTalk is running. Look for the microphone icon in your menu bar."

step 5 "Granting the two permissions."
say_dialog "Two permissions to grant" "System Settings will now open twice.\n\nFirst, under Microphone, switch on PttDictate. That lets NessoTalk hear you.\n\nThen, under Accessibility, switch on PttDictate. That lets NessoTalk type the words for you.\n\nNessoTalk will not record anything until you press the key yourself."
open_settings "Privacy_Microphone"
sleep 3
open_settings "Privacy_Accessibility"

say_dialog "You are ready" "Here is how to use it.\n\n1. Click into any text box, an email, a message, anywhere.\n2. Tap the Right Command key once. A bar appears at the bottom of your screen.\n3. Say whatever you want written.\n4. Tap Right Command again. Your words appear, cleaned up.\n\nPress Escape at any time to throw a recording away.\n\nThat is the whole thing. Try it now."

cat <<'DONE'

  Setup is complete.

  Click into any text box, tap Right Command, say a sentence, then tap
  Right Command again. Your words will appear, cleaned up and punctuated.
  Press Escape while recording to cancel and type nothing.

  The microphone icon in your menu bar shows whether it is listening.
DONE

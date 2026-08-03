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

  This installer takes about three minutes. Most of that is a one time
  download of the speech model. You can leave it running and come back.
BANNER

say_dialog "NessoTalk Setup" "Welcome. This takes about three minutes, and most of it is one download that happens by itself.\n\nAt the end your Mac will ask for two permissions. Both are required: one lets NessoTalk hear you, the other lets it type for you.\n\nClick Continue to begin."

step 1 "Checking the tools NessoTalk needs."
if ! command -v brew >/dev/null; then
  echo "    Homebrew is missing. It is a free installer that Apple does not"
  echo "    include, and NessoTalk uses it to fetch the speech engine."
  say_dialog "One thing is missing" "NessoTalk needs Homebrew, a free tool that installs software on a Mac.\n\nYour browser will now open to brew.sh. Follow the one line of instructions there, then run this installer again."
  open "https://brew.sh"
  exit 1
fi
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
echo "    Done. The speech engine is installed."

step 2 "Downloading the speech model, about 600 MB, one time only."
echo "    This is the part that takes a few minutes. Nothing is required from you."
mkdir -p "$HOME/.whisper-models"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
[ -f "$HOME/.whisper-models/ggml-large-v3-turbo-q5_0.bin" ] || curl -# -L -o "$HOME/.whisper-models/ggml-large-v3-turbo-q5_0.bin" "$BASE/ggml-large-v3-turbo-q5_0.bin"
[ -f "$HOME/.whisper-models/ggml-base.en-q5_1.bin" ] || curl -# -L -o "$HOME/.whisper-models/ggml-base.en-q5_1.bin" "$BASE/ggml-base.en-q5_1.bin"
[ -f "$HOME/.whisper-models/ggml-silero-v5.1.2.bin" ] || curl -# -L -o "$HOME/.whisper-models/ggml-silero-v5.1.2.bin" "$BASE/ggml-silero-v5.1.2.bin"
echo "    Done. Your speech is transcribed by this model, on this Mac."

step 3 "Installing NessoTalk and activating your license."
mkdir -p "$DIR"
cp -f ptt-dictate.swift ptt Info.plist "$DIR/"
[ -f "$DIR/snippets" ] || cp -f snippets.example "$DIR/snippets"
[ -f "$DIR/config" ] || cp -f config.example "$DIR/config"
if [ -n "$KEY" ]; then
  grep -q '^LICENSE_KEY=' "$DIR/config" \
    && sed -i '' -E "s|^LICENSE_KEY=.*|LICENSE_KEY=$KEY|" "$DIR/config" \
    || printf '\nLICENSE_KEY=%s\n' "$KEY" >> "$DIR/config"
  echo "    Your license was found in the download and activated automatically."
else
  echo "    No license key was found in this folder."
  say_dialog "License missing" "This copy does not have a license key inside it, so NessoTalk will install but will not record.\n\nSign in at nesso.tech and download your own copy, which comes with your key already inside."
fi
chmod +x "$DIR/ptt"

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

step 4 "Building and starting NessoTalk. This takes about a minute."
cd "$DIR" && ./ptt build
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

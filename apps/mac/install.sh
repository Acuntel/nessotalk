#!/bin/zsh
# NessoTalk for Mac: beta installer (build-from-source).
# Usage: unzip, then:  cd nessotalk-mac && ./install.sh YOUR-LICENSE-KEY
set -e
KEY="$1"
DIR="$HOME/.dictation"
echo "== NessoTalk installer =="

if ! command -v brew >/dev/null; then
  echo "Homebrew is required. Install it from https://brew.sh then re-run."; exit 1
fi
echo "-> installing whisper-cpp + ffmpeg (brew)"
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg

echo "-> downloading models (~600MB, one time)"
mkdir -p "$HOME/.whisper-models"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
[ -f "$HOME/.whisper-models/ggml-large-v3-turbo-q5_0.bin" ] || curl -L -o "$HOME/.whisper-models/ggml-large-v3-turbo-q5_0.bin" "$BASE/ggml-large-v3-turbo-q5_0.bin"
[ -f "$HOME/.whisper-models/ggml-base.en-q5_1.bin" ] || curl -L -o "$HOME/.whisper-models/ggml-base.en-q5_1.bin" "$BASE/ggml-base.en-q5_1.bin"
[ -f "$HOME/.whisper-models/ggml-silero-v5.1.2.bin" ] || curl -L -o "$HOME/.whisper-models/ggml-silero-v5.1.2.bin" "$BASE/ggml-silero-v5.1.2.bin"

echo "-> installing NessoTalk to $DIR"
mkdir -p "$DIR"
cp -f ptt-dictate.swift ptt Info.plist "$DIR/"
[ -f "$DIR/snippets" ] || cp -f snippets.example "$DIR/snippets"
if [ ! -f "$DIR/config" ]; then cp -f config.example "$DIR/config"; fi
if [ -n "$KEY" ]; then
  grep -q '^LICENSE_KEY=' "$DIR/config" \
    && sed -i '' -E "s/^LICENSE_KEY=.*/LICENSE_KEY=$KEY/" "$DIR/config" \
    || printf '\nLICENSE_KEY=%s\n' "$KEY" >> "$DIR/config"
  echo "-> license key installed"
else
  echo "!! no license key given; get yours at https://nesso.tech and re-run: ./install.sh YOUR-KEY"
fi
chmod +x "$DIR/ptt"

echo "-> writing launchd agent"
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

echo "-> building (first build takes a minute)"
cd "$DIR" && ./ptt build

echo ""
echo "== Almost done. Two one-time permissions =="
echo "System Settings > Privacy & Security > Microphone: enable PttDictate"
echo "System Settings > Privacy & Security > Accessibility: enable PttDictate"
echo "Then tap Right Command and start talking. Esc cancels a recording."

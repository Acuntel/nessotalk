#!/bin/zsh
# Double-clickable installer. Finder opens .command files in Terminal, so this
# is the file customers actually click. It hands off to install.sh, which does
# the work and shows the guided dialogs.
cd "$(dirname "$0")" || exit 1
chmod +x ./install.sh 2>/dev/null
exec ./install.sh

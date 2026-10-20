#!/bin/bash
# Installs Pear: Homebrew tools, the speech models (1.6 GB, once), then builds the app into /Applications and opens it.
# Run it again after `git pull` to update; a call being recorded is saved and transcribed first.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pear"
INSTALLED="/Applications/$APP_NAME.app"
MODELS="$HOME/Library/Application Support/Pear/models"

step() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "Pear needs a Mac with Apple Silicon."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || fail "Pear needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."
xcode-select -p >/dev/null 2>&1 || fail "Install the Xcode Command Line Tools first: xcode-select --install"
command -v brew >/dev/null || fail "Install Homebrew first: https://brew.sh"

step "1/4 Tools: whisper.cpp and ffmpeg"
for tool in whisper-cli whisper-vad-speech-segments ffmpeg; do
    if ! command -v "$tool" >/dev/null; then
        brew install whisper-cpp ffmpeg
        break
    fi
done

step "2/4 Speech models"
mkdir -p "$MODELS"
fetch() {
    if [ -f "$MODELS/$1" ]; then echo "  $1 is already there"; return; fi
    curl -fL --retry 3 --progress-bar -o "$MODELS/$1.part" "$2"
    mv "$MODELS/$1.part" "$MODELS/$1"
}
fetch ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
fetch ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

step "3/4 Building $APP_NAME.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -o "$APP/Contents/MacOS/$APP_NAME" Sources/*.swift
cp Info.plist "$APP/Contents/"
cp transcribe.py AppIcon.icns "$APP/Contents/Resources/"
# A real signing identity, if you have one, keeps macOS permissions across rebuilds; otherwise sign ad hoc.
# Files that came through iCloud carry attributes codesign rejects, so strip them first.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
xattr -cr "$APP"
codesign --force --sign "${IDENTITY:--}" "$APP"

step "4/4 Installing to $INSTALLED"
if pgrep -x "$APP_NAME" >/dev/null; then
    # Quit through Apple Events, not a signal, so a call being recorded is saved and transcribed.
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 150); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
    pgrep -x "$APP_NAME" >/dev/null && fail "$APP_NAME did not quit; quit it from the menu bar and run again."
fi
rm -rf "$INSTALLED"
mv "$APP" "$INSTALLED"
open "$INSTALLED"

step "Done. Look for the pear in the menu bar."
echo "Calls go to ~/Documents/Pear (change it in the menu). Start and stop with the menu or ⌃⌥⌘R."

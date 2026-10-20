#!/bin/bash
# Removes Pear, its speech models, settings and macOS permissions. Your calls folder is left alone.
set -euo pipefail

BUNDLE_ID="com.olevasyliev.pear"
if pgrep -x Pear >/dev/null; then
    osascript -e 'tell application "Pear" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 150); do pgrep -x Pear >/dev/null || break; sleep 0.2; done
fi
rm -rf "/Applications/Pear.app" "$HOME/Library/Application Support/Pear"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "Pear is removed. Your transcripts and audio are still in the calls folder (~/Documents/Pear by default)."

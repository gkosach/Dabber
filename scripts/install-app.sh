#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Applications/Dabber.app
ID=local.dabber.Dabber
if [ -e "$DEST" ] && [ "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$ID" ]; then
  echo "refusing: $DEST exists and is not $ID"
  exit 1
fi
scripts/build-app.sh
running() { pgrep -f "$DEST/Contents/MacOS/Dabber" >/dev/null; }
if running; then
  # Quitting waits for recordings that are still finishing and their transcripts; it can take minutes.
  osascript -e "ignoring application responses" -e "tell application id \"$ID\" to quit" -e "end ignoring"
  echo "waiting for Dabber to quit: it finishes recordings first (up to 10 minutes)"
  for i in {1..600}; do
    running || break
    if (( i % 30 == 0 )); then echo "still waiting for Dabber to quit ($((i / 60)) min $((i % 60)) s)"; fi
    sleep 1
  done
  if running; then
    echo "refusing: Dabber is still running after 10 minutes; quit it and run this again"
    exit 1
  fi
fi
rm -rf "$DEST"
ditto build/Dabber.app "$DEST"
codesign --verify --strict "$DEST"
echo "installed $DEST"

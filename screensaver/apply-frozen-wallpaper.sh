#!/bin/bash
# Applies the screensaver's frozen last frame as the desktop wallpaper.
# Triggered by a LaunchAgent (WatchPaths) whenever the screensaver writes
# lastframe.png on exit. Runs outside the legacyScreenSaver sandbox.

set -u

CONTAINER="$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Ultracode/lastframe.png"
PLAIN="$HOME/Library/Application Support/Ultracode/lastframe.png"

# Pick whichever source exists; newest wins when both do.
SRC=""
if [ -f "$CONTAINER" ] && [ -f "$PLAIN" ]; then
  if [ "$CONTAINER" -nt "$PLAIN" ]; then SRC="$CONTAINER"; else SRC="$PLAIN"; fi
elif [ -f "$CONTAINER" ]; then SRC="$CONTAINER"
elif [ -f "$PLAIN" ]; then SRC="$PLAIN"
else
  exit 0
fi

DST_DIR="$HOME/GitHub/Wallpaper/live"
mkdir -p "$DST_DIR"

# Alternate the destination filename: the wallpaper system caches by path,
# so rewriting the same file would not refresh the desktop.
STATE="$DST_DIR/.which"
if [ "$(cat "$STATE" 2>/dev/null)" = "A" ]; then
  NEW="frozen-B.png"; echo "B" > "$STATE"
else
  NEW="frozen-A.png"; echo "A" > "$STATE"
fi

cp "$SRC" "$DST_DIR/$NEW"

osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$DST_DIR/$NEW\"" 2>/dev/null
exit 0

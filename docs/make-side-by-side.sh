#!/usr/bin/env bash
# make-side-by-side.sh -- capture iTerm2's tmux-integration window and the
# Emacs tmux-control window for the SAME tmux session, composed side by side.
#
# This is how docs/images/iterm-vs-tmux-control.png is produced.  Stand up the
# content first, then run this:
#
#   1. In iTerm2:  tmux -L <socket> -CC attach -t <session>
#                  (iTerm's tmux integration needs `aggressive-resize off`:
#                   tmux -L <socket> set-window-option -g aggressive-resize off)
#   2. In Emacs:   M-x tmux-control-connect to the same session, then C-c C-t
#   3. docs/make-side-by-side.sh <session> [output.png]
#
# Requires ImageMagick (`montage`) and macOS `screencapture`.  No Emacs server
# is needed -- it screenshots the on-screen windows by id.  macOS only.
set -euo pipefail

SESSION="${1:?usage: $0 <tmux-session> [output.png]}"
OUT="${2:-docs/images/iterm-vs-tmux-control.png}"
TMPI="${TMPDIR:-/tmp}/sxs-iterm.$$.png"
TMPE="${TMPDIR:-/tmp}/sxs-emacs.$$.png"
trap 'rm -f "$TMPI" "$TMPE"' EXIT

caffeinate -u -t 2 >/dev/null 2>&1 &   # wake the display if it is asleep

# --- iTerm2: find the tmux-integration window, named "tmux:<session> | ..." ---
osascript -e 'tell application "iTerm" to activate' >/dev/null 2>&1
sleep 0.4
ITERM_ID="$(osascript <<OSA
tell application "iTerm"
  repeat with w in windows
    if name of w contains "tmux:${SESSION}" then
      select w
      return id of w
    end if
  end repeat
  return ""
end tell
OSA
)"
if [ -z "$ITERM_ID" ]; then
  echo "error: no iTerm window named 'tmux:${SESSION}'." >&2
  echo "  attach it first:  tmux -CC attach -t ${SESSION}  (needs aggressive-resize off)" >&2
  exit 1
fi
sleep 0.5
screencapture -x -o -l "$ITERM_ID" "$TMPI"

# --- Emacs: the frontmost window (the tmux-control frame) ---
osascript -e 'tell application "Emacs" to activate' >/dev/null 2>&1
sleep 0.5
EMACS_ID="$(osascript -e 'tell application "Emacs" to id of window 1')"
screencapture -x -o -l "$EMACS_ID" "$TMPE"

# --- compose: labeled tiles, matched height, dark gutter ---
# ImageMagick on macOS often has no default font configured, so name one.
FONT="/System/Library/Fonts/Helvetica.ttc"
[ -f "$FONT" ] || FONT="/System/Library/Fonts/Menlo.ttc"
mkdir -p "$(dirname "$OUT")"
montage \
  -label 'iTerm2  --  native tmux integration' "$TMPI" \
  -label 'Emacs  --  tmux-control' "$TMPE" \
  -tile 2x1 -geometry 'x760+8+10' \
  -background '#1c1c1c' -fill '#d0d0d0' -font "$FONT" -pointsize 18 \
  "$OUT"

echo "wrote $OUT"

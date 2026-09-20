#!/bin/bash
# Launch ONE patch in a fresh Max with FFGL tracing on. Max restores its previous workspace on
# launch (Crash Recovery/maxworkspace-*.txt), which re-opens every earlier test patch, so clear it first.
# usage: run_max_patch.sh <patch.maxpat> <trace-file>
osascript -e 'tell application "Max" to quit' 2>/dev/null
while pgrep -f "MacOS/Max$" >/dev/null; do sleep 1; done; sleep 1
rm -f "$HOME/Library/Application Support/Cycling '74/Max 9/Crash Recovery/"maxworkspace-*.txt
rm -f "$2"
open -a Max --env FFGL_TRACE="$2" "$1"

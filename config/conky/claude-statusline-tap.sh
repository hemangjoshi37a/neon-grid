#!/bin/sh
# Claude Code status line for the Neon-Grid rice.
# 1. Saves the status JSON (it carries the plan usage limits) for the desktop deck.
# 2. Prints the Neon-Grid status lines.
# 3. Runs the previous status line command, if one was configured
#    (stored in ~/.config/neon-grid/statusline-next), underneath.
f="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-status.json"
next="$HOME/.config/neon-grid/statusline-next"
input=$(cat)
printf '%s' "$input" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
printf '%s' "$input" | python3 "$HOME/.config/conky/neon-statusline.py"
if [ -s "$next" ]; then
    printf '%s' "$input" | sh -c "$(cat "$next")"
fi

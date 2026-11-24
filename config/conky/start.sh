#!/bin/sh
# Starts the Neon-Grid desktop widgets.
# The older separate widgets (neon-hud, neon-day, neon-deck .conf) are kept in
# this folder but no longer started; the unified panel replaces them.
rm -f "$HOME/.cache/neon-grid/splash-tries"      # the desktop came up: the welcome screen may show again
mkdir -p "$HOME/.cache/neon-grid"; xrandr --current --listmonitors > "$HOME/.cache/neon-grid/screens.txt" 2>/dev/null   # for the glass
pgrep -x conky >/dev/null && { killall -q conky; sleep 1; }
conky -c "$HOME/.config/conky/neon-panel.conf" >/dev/null 2>&1 &
conky -c "$HOME/.config/conky/neon-gsc.conf" >/dev/null 2>&1 &
conky -c "$HOME/.config/conky/neon-toggle.conf" >/dev/null 2>&1 &     # the hide/show button
[ -e "$HOME/.cache/neon-grid/widgets-hidden" ] && "$HOME/.config/conky/neon-widgets" apply 6 >/dev/null 2>&1 &
[ -x "$HOME/.local/share/neon-grid/neon-layout" ] && "$HOME/.local/share/neon-grid/neon-layout" save &

#!/usr/bin/env bash
# Neon-Grid rice installer for Cinnamon (X11) on Ubuntu/Debian/Mint.
# Usage: ./install.sh            (asks for sudo once, for apt)
# Existing settings are saved to ~/.local/share/neon-grid/backup-<date>/ first.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BK="$HOME/.local/share/neon-grid/backup-$(date +%Y%m%d-%H%M%S)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

say "Backing up current settings to $BK"
mkdir -p "$BK"
dconf dump /org/cinnamon/ > "$BK/cinnamon.dconf"
dconf dump /org/gnome/terminal/ > "$BK/gnome-terminal.dconf" || true
dconf dump /org/gnome/desktop/interface/ > "$BK/gnome-interface.dconf" || true
cp -a "$HOME/.bashrc" "$BK/bashrc.bak" 2>/dev/null || true
[ -f "$HOME/.claude/settings.json" ] && cp -a "$HOME/.claude/settings.json" "$BK/claude-settings.json.bak"
for d in conky kitty rofi fastfetch; do
    [ -e "$HOME/.config/$d" ] && cp -a "$HOME/.config/$d" "$BK/$d"
done
[ -f "$HOME/.config/gtk-3.0/gtk.css" ] && cp -a "$HOME/.config/gtk-3.0/gtk.css" "$BK/gtk.css"
[ -f "$HOME/.config/starship.toml" ] && cp -a "$HOME/.config/starship.toml" "$BK/starship.toml"

say "Installing packages"
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    conky-all kitty rofi fastfetch btop starship papirus-icon-theme bibata-cursor-theme \
    fonts-jetbrains-mono fonts-font-awesome lm-sensors jq python3-psutil python3-pil python3-numpy python3-venv xdotool \
    gcc libc6-dev pkg-config libcairo2-dev libx11-dev libxext-dev libxrandr-dev libxcomposite-dev libgtk-3-dev

say "Installing theme, font, configs and extension"
mkdir -p "$HOME/.themes" "$HOME/.local/share/fonts" "$HOME/.config/gtk-3.0" \
    "$HOME/.local/share/cinnamon/extensions" "$HOME/.config/systemd/user" \
    "$HOME/.config/autostart" "$HOME/.config/neon-grid"
rm -rf "$HOME/.themes/Neon-Grid"
cp -r "$HERE/themes/Neon-Grid" "$HOME/.themes/"
cp "$HERE/fonts/Orbitron.ttf" "$HOME/.local/share/fonts/" && fc-cache -f
for d in conky kitty rofi fastfetch; do
    mkdir -p "$HOME/.config/$d" && cp -r "$HERE/config/$d/." "$HOME/.config/$d/"
done
cp "$HERE/config/starship.toml" "$HOME/.config/starship.toml"
cp "$HERE/config/gtk-3.0/gtk.css" "$HOME/.config/gtk-3.0/gtk.css"
[ -f "$HOME/.config/gtk-3.0/settings.ini" ] || \
    printf '[Settings]\ngtk-application-prefer-dark-theme=1\n' > "$HOME/.config/gtk-3.0/settings.ini"
cp -r "$HERE/extensions/neon-opacity@hjlabs" "$HOME/.local/share/cinnamon/extensions/"
cp -r "$HERE/extensions/neon-genie@hjlabs" "$HOME/.local/share/cinnamon/extensions/"
cp -r "$HERE/extensions/neon-motion@hjlabs" "$HOME/.local/share/cinnamon/extensions/"
cp -r "$HERE/extensions/neon-notify@hjlabs" "$HOME/.local/share/cinnamon/extensions/"
chmod +x "$HOME/.config/conky/"*.sh "$HOME/.config/conky/"*.py "$HOME/.config/conky/neon-act" "$HOME/.config/conky/neon-widgets"

say "Setting up wallpaper colours (neon-palette)"
cp -r "$HERE/config/neon-grid/neon-palette.py" "$HERE/config/neon-grid/neon-safe" "$HERE/config/neon-grid/new-tab" "$HOME/.config/neon-grid/"
cp "$HERE/systemd/neon-palette.service" "$HOME/.config/systemd/user/"
chmod +x "$HOME/.config/neon-grid/neon-palette.py" "$HOME/.config/neon-grid/neon-safe"
mkdir -p "$HOME/.local/bin" && ln -sfn "$HOME/.config/neon-grid/neon-safe" "$HOME/.local/bin/neon-safe"
mkdir -p "$HOME/.local/bin" && ln -sfn "$HOME/.config/neon-grid/neon-palette.py" "$HOME/.local/bin/neon-palette"
if python3 -m venv --system-site-packages "$HOME/.local/share/neon-grid/venv" &&
   "$HOME/.local/share/neon-grid/venv/bin/pip" install -q --no-cache-dir --only-binary=:all: 'materialyoucolor==3.0.4'; then
    systemctl --user daemon-reload
    systemctl --user enable neon-palette.service
    APPLY_PALETTE=1
else
    say "materialyoucolor not available; staying on the neon colours"
fi

IFACE="$(ip -br link | awk '$2=="UP" && $1 ~ /^(wl|en|eth)/{print $1; exit}')"
sed -i "s/@IFACE@/${IFACE:-lo}/g" "$HOME/.config/conky/neon-hud.conf"

# The Search Console board needs a service-account key (see .env.example) and a second monitor.
[ -f "$HOME/.config/neon-grid/.env" ] || install -m 600 "$HERE/config/neon-grid/.env.example" "$HOME/.config/neon-grid/.env"
envget() { sed -n "s/^$1=//p" "$HOME/.config/neon-grid/.env" | head -1 | sed "s#^~#$HOME#"; }
GSC_PY="$(envget NEON_GSC_PYTHON)"; GSC_KEY="$(envget NEON_GSC_KEY)"; GSC_DOMAIN="$(envget NEON_GSC_DOMAIN)"
HAVE_GSC=0
if [ -n "$GSC_DOMAIN" ] && [ -x "$GSC_PY" ] && [ -f "$GSC_KEY" ] && [ "$(xrandr --listmonitors | head -1 | awk '{print $2}')" -ge 2 ]; then
    HAVE_GSC=1
else
    sed -i '/neon-gsc.conf/d' "$HOME/.config/conky/start.sh"
    say "Skipping Search Console board (needs ~/.config/neon-grid/.env and a second monitor)"
fi

say "Welcome screen between login and desktop"
NG="$HOME/.local/share/neon-grid"; mkdir -p "$NG"
cp "$HERE/login/neon-warm" "$HERE/login/neon-layout" "$HERE/login/neon-splash-start" "$NG/" && chmod +x "$NG/neon-warm" "$NG/neon-layout" "$NG/neon-splash-start"
cp "$HERE/login/neon-warm.service" "$HOME/.config/systemd/user/" && systemctl --user daemon-reload && systemctl --user enable neon-warm.service || true
if command -v cc >/dev/null && pkg-config --exists cairo x11 xext xrandr xcomposite &&
   cc -O2 -o "$NG/neon-splash" "$HERE/login/neon-splash.c" $(pkg-config --cflags --libs cairo x11 xext xrandr xcomposite) -lm; then
    grep -q neon-splash-start "$HOME/.xprofile" 2>/dev/null || cat "$HERE/login/xprofile" >> "$HOME/.xprofile"
    gsettings set org.cinnamon startup-animation false || true
else
    say "Welcome screen skipped (needs gcc and libcairo2-dev libxrandr-dev libxext-dev libxcomposite-dev)"
fi

say "Smooth wheel scrolling in Nemo and GNOME Terminal"
"$HERE/scroll/install" || say "Smooth scrolling skipped (needs gcc and libgtk-3-dev)"

say "Applying desktop settings"
gs() { gsettings set "$@" || true; }
gs org.cinnamon.desktop.interface gtk-theme 'Neon-Grid'
gs org.cinnamon.desktop.interface icon-theme 'Papirus-Dark'
gs org.cinnamon.desktop.interface cursor-theme 'Bibata-Modern-Ice'
gs org.cinnamon.theme name 'Neon-Grid'
gs org.cinnamon.desktop.wm.preferences theme 'Neon-Grid'
gs org.cinnamon.desktop.wm.preferences titlebar-font 'Orbitron Bold 9'
gs org.gnome.desktop.interface gtk-theme 'Neon-Grid'
gs org.gnome.desktop.interface icon-theme 'Papirus-Dark'
gs org.gnome.desktop.interface cursor-theme 'Bibata-Modern-Ice'
gs org.gnome.desktop.interface color-scheme 'prefer-dark'
gs org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 11'
gs org.x.apps.portal color-scheme 'prefer-dark'
gs org.cinnamon.desktop.default-applications.terminal exec 'kitty'
gs org.cinnamon desktop-effects-map 'fly'
gs org.cinnamon desktop-effects-close 'fly'
gs org.cinnamon desktop-effects-minimize 'traditional'
# The genie extension takes over Cinnamon's minimize/restore animations, so
# these must stay animated ('traditional' minimize, any non-'none' map effect).
# extensions that are already on stay on
gs org.cinnamon enabled-extensions "$(gsettings get org.cinnamon enabled-extensions | python3 -c '
import ast, sys
t = sys.stdin.read().strip()
on = [] if t.startswith("@as") else ast.literal_eval(t)
print(on + [e for e in ("neon-opacity@hjlabs", "neon-genie@hjlabs", "neon-motion@hjlabs", "neon-notify@hjlabs") if e not in on])')"

# rofi launcher on Super+Space (only if no custom keybindings exist yet)
if [ "$(gsettings get org.cinnamon.desktop.keybindings custom-list)" = "@as []" ]; then
    P=/org/cinnamon/desktop/keybindings/custom-keybindings/custom0/
    dconf write "${P}name" "'Neon launcher'"
    dconf write "${P}command" "'rofi -show drun'"
    dconf write "${P}binding" "['<Super>space']"
    gs org.cinnamon.desktop.keybindings custom-list "['custom0']"
else
    say "Custom keybindings already exist; add 'rofi -show drun' yourself if you want the launcher"
fi

# gnome-terminal profile
PROF="$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'")"
if [ -n "$PROF" ]; then
    dconf load "/org/gnome/terminal/legacy/profiles:/:$PROF/" < "$HERE/gnome-terminal-profile.dconf"
    gs org.gnome.Terminal.Legacy.Settings theme-variant 'dark'
fi

# shell prompt
if ! grep -q "Neon-Grid rice" "$HOME/.bashrc" 2>/dev/null; then
cat >> "$HOME/.bashrc" <<'RC'

# >>> Neon-Grid rice >>>
if [[ $- == *i* ]]; then
    command -v starship >/dev/null && eval "$(starship init bash)"
    [[ $TERM == xterm-kitty ]] && command -v fastfetch >/dev/null && fastfetch
    alias top='btop'
fi
# <<< Neon-Grid rice <<<
RC
fi

# Claude Code status-line tap (feeds the usage card on the deck)
CS="$HOME/.claude/settings.json"
if [ -f "$CS" ]; then
    CUR="$(jq -r '.statusLine.command // empty' "$CS")"
    TAP="$HOME/.config/conky/claude-statusline-tap.sh"
    if [ "$CUR" != "$TAP" ]; then
        printf '%s\n' "$CUR" > "$HOME/.config/neon-grid/statusline-next"
        jq --arg c "$TAP" '.statusLine = ((.statusLine // {type:"command"}) | .type="command" | .command=$c)' \
            "$CS" > "$CS.neon" && mv "$CS.neon" "$CS"
    fi
fi

say "Starting services and widgets"
cp "$HERE/systemd/neon-deck.service" "$HOME/.config/systemd/user/"
if [ "$HAVE_GSC" = 1 ]; then
    cp "$HERE/systemd/neon-gsc.service" "$HERE/systemd/neon-gsc.timer" "$HOME/.config/systemd/user/"
fi
systemctl --user daemon-reload
systemctl --user enable --now neon-deck.service
[ "$HAVE_GSC" = 1 ] && systemctl --user enable --now neon-gsc.timer && systemctl --user start neon-gsc.service || true
cat > "$HOME/.config/autostart/neon-hud.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Neon-Grid widgets
Comment=Conky desktop widgets
Exec=sh -c "$HOME/.config/conky/start.sh; sleep 45; $HOME/.local/share/neon-grid/neon-warm learn"
X-GNOME-Autostart-enabled=true
DESK
"$HOME/.config/conky/start.sh"

say "Done. Log out and back in (or press Alt+F2, type r, Enter) so every app picks up the theme."
say "Backup of the previous settings: $BK"

# last, once the theme names above are set
[ "${APPLY_PALETTE:-0}" = 1 ] && { "$HOME/.local/bin/neon-palette" wallpaper || true; systemctl --user restart neon-palette.service || true; }
exit 0

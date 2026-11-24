# Guide for AI coding agents

You are setting up Neon-Grid on someone's computer. Read this file to the end before running anything. People
depend on this computer (and often on the session you are running in): **a machine that cannot be reached any
more is the one result that is never acceptable.**

## 1. Rules

1. Say what you are about to do and get a yes before: installing packages, anything with `sudo`, anything in
   `/boot`, logging out, restarting Cinnamon, rebooting.
2. Never ask for a password in chat, store one or pass one on a command line. Let the person type it
   (`sudo` in their terminal, or `pkexec`). Do not use `docker` or `lxd` group membership to become root.
3. Desktop first (section 3). Only when that works, offer the boot parts (section 4), one at a time.
4. Never edit files that belong to packages, never run `update-initramfs`, `dracut`, `update-grub` by hand:
   `neon-boot` does this with checks.
5. Keep the arrangement of the person's panel and their wallpaper applet. Only styling changes.
6. Never commit `.env`, keys, host names, site lists or screenshots of a real desktop.
7. Do not open menus or move the pointer on a desktop somebody is using.
8. Report what you saw, not what should have happened. Section 7 says what nobody has tested yet.

## 2. Check the machine (reads only)

```sh
. /etc/os-release; echo "$PRETTY_NAME"; echo "$XDG_CURRENT_DESKTOP $XDG_SESSION_TYPE"; cinnamon --version
df -h / /boot /boot/efi; xrandr --listmonitors; cat /etc/X11/default-display-manager
gnome-shell --version; grub-install --version; command -v dracut update-initramfs plymouth
gsettings get org.cinnamon enabled-extensions; gsettings get org.cinnamon.desktop.keybindings custom-list
```

| Found | Do |
| --- | --- |
| Not Cinnamon | Stop: the theme, extensions and widgets are for Cinnamon |
| Wayland session | Stop and ask; the widgets and extensions expect X11 |
| Not apt based | Install the package list from `install.sh` by hand, then follow its other steps |
| Display manager is not GDM | Leave out `login` in section 4 |
| GNOME Shell is not 51 | `login` gives the look; the login animation stays off |
| No GRUB, or no Plymouth | Leave out `grub` or `splash` |
| Less than 4 GB free where `/boot` lives | `neon-boot` refuses. Do not delete things to make room without asking |
| Laptop screen is not 1920×1080 | Sizes are at the top of `config/conky/neon-panel.{conf,lua}`; adjust and check by screenshot |

Ask the person: Is the second monitor and Search Console board wanted? Boot screens too? Do they want to keep
extensions, terminal settings or a `.bashrc` prompt that `install.sh` would add to?

## 3. Desktop

Read `install.sh` first. What it changes: apt packages; `~/.themes/Neon-Grid`; `~/.config/{conky,kitty,rofi,
fastfetch,gtk-3.0,starship.toml,neon-grid}`; four Cinnamon extensions (others stay on); a wrapper `~/.local/bin/nemo`, a D-Bus entry for Nemo and a
drop-in for gnome-terminal-server (smooth scrolling; `scroll/install --remove` takes them away); gsettings for theme,
icons, cursor, default terminal and effects; the default gnome-terminal profile; blocks in `~/.bashrc` and
`~/.xprofile`; the status line in `~/.claude/settings.json`; user services. It **replaces** existing kitty, rofi,
fastfetch, starship and `gtk.css` files. Copies go to `~/.local/share/neon-grid/backup-<date>/`.

```sh
./install.sh
```

It asks for sudo (apt), so the person has to run it or enter the password. Afterwards:

```sh
pgrep -c -x conky                                          # 2, or 3 with the Search Console board (one is the hide button)
systemctl --user is-active neon-deck neon-palette          # active, active
gsettings get org.cinnamon enabled-extensions              # contains the four neon-* ones
neon-palette show
journalctl --user -b --since '-5 min' | grep -iE 'neon-|JS ERROR'
```

Then ask the person to log out and in. Look at the result with a screenshot of a widget's own window:
`xwininfo -root -tree | grep '"neon-panel"'`, then `import -window <id> file.png`.

**Search Console board** (optional): a service account with read access to the property. The person places the
key file; you fill in `~/.config/neon-grid/.env` (mode 600) and run `install.sh` again. The Python named there
needs `google-auth` and `google-api-python-client`. Check: `systemctl --user start neon-gsc.service`, then
`~/.cache/neon-grid/gsc-28.txt` exists.

**Browsers** (optional, by the person): extensions page → developer mode → *Load unpacked* →
`~/.local/share/neon-grid/browser/new-tab` or `…/opera-mod`.

## 4. Boot, GRUB and login (optional, root)

Before: make sure there is another way in (a second kernel or recovery entry in GRUB, `ssh`, or at least that
the person knows `Ctrl+Alt+F3`). Tell them the undo command.

```sh
sudo ./boot/neon-boot install speed      # boot order; nothing visible
sudo ./boot/neon-boot install login      # takes effect at the next login screen
sudo ./boot/neon-boot install grub
sudo ./boot/neon-boot install splash     # builds a new boot image beside the old one, verifies, swaps
neon-boot status
```

Run it from the person's own account with `sudo` (or `SUDO_USER` set), not from a root shell. Every part prints
`ok` or undoes itself. After `grub` and before a reboot:

```sh
sudo grub-script-check /boot/grub/grub.cfg && sudo grep -c '^menuentry' /boot/grub/grub.cfg
ls -l /boot/vmlinuz-"$(uname -r)" /boot/initrd.img-"$(uname -r)"; systemctl is-active ssh
```

Do not reboot by yourself. Ask, and say what to expect: menu, boot animation, login, welcome, desktop.

| Trouble | Way back |
| --- | --- |
| Desktop looks wrong | `neon-safe` |
| Login screen broken | `Ctrl+Alt+F3`, log in, `sudo neon-boot revert login` |
| Stuck in the boot animation | `Esc` shows the messages; or `e` in GRUB and remove `splash` |
| Boot image | previous one: `/var/lib/neon-grid/initrd.before` |
| Everything | `sudo neon-boot revert`, then `neon-safe` |
| Nobody does anything | `neon-safeguard` returns to stock after two boots without a working login screen |

## 5. Changing things

Edit the live file, apply, look, then copy it into the repository.

| Changed | Apply |
| --- | --- |
| Conky files | `~/.config/conky/start.sh` |
| `neon-deck.py`, `neon-gsc.py` | `systemctl --user restart neon-deck`, `systemctl --user start neon-gsc` |
| `~/.themes/Neon-Grid` | `neon-palette refresh --force`. Never edit the generated `Neon-Grid-You-*`. Edit `gtk.css` **and** `gtk-dark.css` |
| A Cinnamon extension | take it out of `enabled-extensions` and put it back |
| `login/neon-splash.c` | build line is in `install.sh` |
| `scroll/` | `scroll/install`; new Nemo and GNOME Terminal processes use it |
| Anything in `boot/` or `login/greeter/` | `sudo ./boot/neon-boot install <part>` |

## 6. Traps that cost time here

- **Never start a second Cinnamon or GNOME with a plain `dbus-run-session`.** Its dconf writes into the real
  profile (panel layout, wallpaper). Use `env -i` with its own `HOME` and `XDG_*`, plus
  `GSETTINGS_BACKEND=keyfile`, and compare `sha256sum ~/.config/dconf/user` before and after.
- Cinnamon expects only windows in the window groups; put other actors in `Main.uiGroup` or `global.stage`.
- Genie needs minimize effect `traditional` and a map effect other than `none`.
- Conky: share one `cairo_text_extents_t` (it is never freed); call `cairo_new_path` before every `cairo_arc`;
  a mouse event does not wake Conky, so the idle frame rate is the hover delay.
- `xrandr` without `--current` probes the screens and freezes the picture for a moment.
- GRUB `gfxmenu`: use three-piece bars (w, c, e); top and bottom pieces move the selected row.
- The GRUB, welcome and login pictures must match pixel by pixel where one hands over to the next. The login
  animation ends at rest, and `neon-splash` starts from the same pose. Do not fade to black between them.
- Plymouth passes only Tab, Enter, Backspace and Esc to a theme; Esc always opens its own text. A variable first assigned
  inside a function is local to it, and strings know no `\t`. Test with a dracut image in QEMU, without a serial console
  (that forces text mode); pad the image to 512 bytes before appending a cpio with changed files.
- A logo that cannot be read must never stop the install: own picture → firmware (BGRT) → maker's name → plain computer.
- Root code never reads files from a home directory directly: colours are validated and the wallpaper is decoded
  by an unprivileged child process. Keep it that way.

Pictures for documentation: `tools/demo.py <home> <runtime dir>`, run with neon-palette's Python
(`~/.local/share/neon-grid/venv/bin/python`), writes invented data. Then run Conky in Xvfb with `HOME` and
`XDG_RUNTIME_DIR` pointing there.

## 7. Not tested

`install.sh` from start to finish on a fresh machine; distributions other than Ubuntu 26.10; GRUB and Plymouth on
machines other than one HP Victus (and QEMU); Wayland. If something here fails on your machine, stop, put it back
and tell the person what you saw.

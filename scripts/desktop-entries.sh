#!/usr/bin/env bash
# Tidy up after Wine's menu builder: point the menu entry at the launcher, and take
# away the desktop shortcut altogether.
#
#   desktop-entries.sh [prefix] [launcher]
#
# Wine's menu builder generates a .desktop for CAM that runs `wine <the .lnk>`
# directly. That starts CAM with none of the things the launcher does for it: no GPU
# poller, so every GPU reading sits at n/a; no device fixups, so the cooler goes
# missing after a Wine restart; no capture-card guard and no crash supervisor, so one
# click on that page leaves the app blank for good. So the menu entry is rewritten
# rather than left as a second, quieter way to start the app.
#
# The desktop shortcut is deleted rather than rewritten. CAM is a tray application
# that is normally started once and left alone; an icon dropped on the desktop by an
# installer is clutter nobody asked for. The .lnk it was generated from goes with it,
# otherwise Wine puts the shortcut back the next time it reads the prefix.
#
# Rewriting is safe: Wine only regenerates these when it processes the .lnk again, on
# an install or a prefix update, not on an ordinary start. The launcher re-runs this
# each time it starts, which picks up any that a CAM update recreated.
set -euo pipefail

PREFIX="${1:-${WINEPREFIX:-$HOME/pfx/nzxt_cam}}"
LAUNCHER="${2:-$HOME/.local/bin/nzxt-cam}"
quiet="${NZXT_CAM_QUIET:-}"

say() { [ -n "$quiet" ] || echo "$@"; }

# The desktop folder is not always ~/Desktop -- it is localised, and can be moved.
DESKTOP_DIR="$HOME/Desktop"
if [ -r "$HOME/.config/user-dirs.dirs" ]; then
    d="$(. "$HOME/.config/user-dirs.dirs" 2>/dev/null; printf '%s' "${XDG_DESKTOP_DIR:-}")"
    [ -n "$d" ] && DESKTOP_DIR="$d"
fi

# Ours only: an entry has to name this prefix, so a second prefix's CAM (or somebody
# else's Wine app) is left alone -- and it has to actually start CAM, rather than be
# one of Wine's file-association entries that merely mention the prefix.
is_cam_entry() {
    grep -q -F -e "WINEPREFIX=$PREFIX" -e "Path=$PREFIX" -e "$LAUNCHER" "$1" 2>/dev/null || return 1
    grep -qi -e 'Exec=.*NZXT CAM\.lnk' -e 'Exec=.*NZXT CAM\.exe' -e "Exec=$LAUNCHER" "$1" 2>/dev/null
}

changed=0

# ---------------------------------------------------------------- desktop shortcut

# The shortcuts themselves...
for dir in "$DESKTOP_DIR" "$PREFIX/drive_c/users/$USER/Desktop" "$PREFIX/drive_c/users/Public/Desktop"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
        case "$f" in
            *.desktop) is_cam_entry "$f" || continue ;;
        esac
        rm -f "$f" 2>/dev/null && { say "    removed $f"; changed=1; } || true
    done < <(find "$dir" -maxdepth 1 \( -name '*NZXT CAM*.lnk' -o -name '*.desktop' \) -print0 2>/dev/null)
done

# ...and the .lnk anywhere else in the prefix that names the desktop, so that Wine's
# menu builder has nothing left to regenerate one from.
if [ -d "$PREFIX/drive_c" ]; then
    while IFS= read -r -d '' f; do
        rm -f "$f" 2>/dev/null && { say "    removed $f"; changed=1; } || true
    done < <(find "$PREFIX/drive_c" -path '*/Desktop/*NZXT CAM*.lnk' -print0 2>/dev/null)
fi

# ------------------------------------------------------------------- menu entries

if [ -x "$LAUNCHER" ]; then
    for dir in "$HOME/.local/share/applications" "$HOME/.config/autostart"; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' f; do
            is_cam_entry "$f" || continue
            # Already ours -- and that includes the start-on-login entry, whose Exec
            # carries a --startup this rewrite would quietly drop.
            grep -q -F "Exec=$LAUNCHER" "$f" 2>/dev/null && continue

            # Keep the icon, the name and StartupWMClass -- that last one is what lets
            # the desktop match CAM's window to this entry, so the taskbar shows the
            # icon rather than a generic Wine one. Only Exec and Path change.
            tmp="$(mktemp)"
            awk -v launcher="$LAUNCHER" '
                /^Exec=/ { print "Exec=" launcher; next }
                /^Path=/ { next }               # the launcher changes directory itself
                { print }
            ' "$f" > "$tmp"

            if cmp -s "$tmp" "$f"; then
                rm -f "$tmp"
            else
                cat "$tmp" > "$f"               # preserve the file's mode and ownership
                rm -f "$tmp"
                say "    $f"
                changed=1
            fi
        done < <(find "$dir" -name '*.desktop' -print0 2>/dev/null)
    done
else
    say "no launcher at $LAUNCHER -- leaving the menu entries alone"
fi

if [ "$changed" = 1 ]; then
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
fi
exit 0

#!/usr/bin/env bash
# Remove everything the NZXT CAM install put on this machine.
#
#   curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/uninstall.sh | bash
#
# Removes the Wine prefix (CAM itself, its settings and logs all live inside it), CAM's
# own copy of Wine, the launcher, and the menu entries and icons Wine's menu builder
# created, and the udev rule that grants access to the device. Only that rule lives
# outside $HOME, and removing it is the one step that needs root.
#
# Non-interactive use:
#   ASSUME_YES=1 bash uninstall.sh
set -euo pipefail

say()  { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# When piped from curl, stdin is the script -- prompts must come from the terminal.
if [ -r /dev/tty ] && [ -t 1 ]; then TTY=/dev/tty; else TTY=""; fi
confirm() {
    local reply=""
    if [ -n "${ASSUME_YES:-}" ]; then return 0; fi
    if [ -z "$TTY" ]; then return 1; fi
    read -r -p "$1 [y/N]: " reply < "$TTY" || reply=""
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

LAUNCHER="$HOME/.local/bin/nzxt-cam"

# Which prefix? The launcher records it, so prefer that over guessing.
PREFIX="${WINEPREFIX:-}"
if [ -z "$PREFIX" ] && [ -f "$LAUNCHER" ]; then
    PREFIX="$(sed -n 's/^export WINEPREFIX="\(.*\)"$/\1/p' "$LAUNCHER" | head -1)"
fi
PREFIX="${PREFIX:-$HOME/pfx/nzxt_cam}"

# ------------------------------------------------------------------ what we found

say "Looking for an installation"
echo "    prefix: $PREFIX"

FOUND=0
PREFIX_OK=0
if [ -d "$PREFIX" ]; then
    # Only ever delete something that really is a Wine prefix, never a stray path.
    if [ -d "$PREFIX/drive_c" ] && [ -f "$PREFIX/system.reg" ]; then
        PREFIX_OK=1; FOUND=1
        echo "    found Wine prefix ($(du -sh "$PREFIX" 2>/dev/null | cut -f1))"
    else
        warn "$PREFIX exists but is not a Wine prefix -- leaving it alone."
    fi
fi
[ -f "$LAUNCHER" ] && { FOUND=1; echo "    found launcher: $LAUNCHER"; }

# The launcher supervises CAM and restarts it after a crash, so a running instance
# has to be stopped before anything is removed -- otherwise it can put CAM back
# halfway through the removal.
# Matching on the launcher's path also matches this script's own command line, and
# anything that merely mentions it, so never take pgrep's word for it: drop ourselves,
# our parent, and any process whose command line is not actually the launcher.
launcher_pids() {
    local pid cmd
    command -v pgrep >/dev/null 2>&1 || return 0
    for pid in $(pgrep -f "$LAUNCHER" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" || continue
        case "$cmd" in
            *uninstall*) continue ;;                 # this script
            *"$LAUNCHER"*) printf '%s\n' "$pid" ;;   # a real launcher
        esac
    done
}

RUNNING="$(launcher_pids | wc -l)"
if [ "$RUNNING" -gt 0 ] 2>/dev/null; then
    FOUND=1
    echo "    found $RUNNING running launcher process(es)"
fi

# Menu entries and icons that Wine's menu builder generated. These live in shared XDG
# directories next to every other application, so they cannot be removed a directory at
# a time -- but nothing here is a fixed list either: entries are discovered, by what
# they point at (any file naming this prefix is ours) and by name, so anything CAM
# gains later is still found. Whole directories are taken whole where they are ours.
XDG_DIRS=(
    "$HOME/.local/share/applications"
    "$HOME/.config/menus"
    "$HOME/.local/share/desktop-directories"
    "$HOME/.config/autostart"
    "$HOME/Desktop"
)

DESKTOP_DIRS=()
DESKTOP_ITEMS=()
seen_item() { local i; for i in "${DESKTOP_ITEMS[@]:-}"; do [ "$i" = "$1" ] && return 0; done; return 1; }

for d in "${XDG_DIRS[@]}"; do
    [ -d "$d" ] || continue
    # Directories belonging to CAM go wholesale, with whatever is inside them.
    while IFS= read -r -d '' sub; do DESKTOP_DIRS+=("$sub"); done < <(
        find "$d" -type d -iname "*NZXT*" -print0 2>/dev/null)
    # Files that name this prefix or the launcher, whatever they are called. The
    # autostart entry names the launcher rather than the prefix, for instance.
    while IFS= read -r -d '' f; do
        seen_item "$f" || DESKTOP_ITEMS+=("$f")
    done < <(grep -rlZ -F -e "$PREFIX" -e "$LAUNCHER" "$d" 2>/dev/null)
    # ...and files named for CAM, which is how icons are identifiable at all.
    while IFS= read -r -d '' f; do
        seen_item "$f" || DESKTOP_ITEMS+=("$f")
    done < <(find "$d" -type f -iname "*NZXT*" -print0 2>/dev/null)
done

# Icons carry no path inside them, so they can only be matched by name.
if [ -d "$HOME/.local/share/icons" ]; then
    while IFS= read -r -d '' f; do
        seen_item "$f" || DESKTOP_ITEMS+=("$f")
    done < <(find "$HOME/.local/share/icons" -iname "*NZXT*" -print0 2>/dev/null)
fi

if [ ${#DESKTOP_DIRS[@]} -gt 0 ] || [ ${#DESKTOP_ITEMS[@]} -gt 0 ]; then
    FOUND=1
    echo "    found $(( ${#DESKTOP_DIRS[@]} + ${#DESKTOP_ITEMS[@]} )) menu entr(ies)/icon(s)"
fi

# CAM's private copy of Wine. The launcher records where it is, same as the prefix.
WINETREE="${NZXT_CAM_WINE_TREE:-}"
if [ -z "$WINETREE" ] && [ -f "$LAUNCHER" ]; then
    WINETREE="$(sed -n 's/^WINETREE="\(.*\)"$/\1/p' "$LAUNCHER" | head -1)"
fi
WINETREE="${WINETREE:-$HOME/.local/share/nzxt-cam/wine}"
DATADIR="$HOME/.local/share/nzxt-cam"
TREE_FOUND=0
if [ -d "$WINETREE" ] && [ -x "$WINETREE/bin/wine" ]; then
    TREE_FOUND=1; FOUND=1
    echo "    found private Wine tree ($(du -sh "$WINETREE" 2>/dev/null | cut -f1))"
elif [ -d "$DATADIR" ]; then
    FOUND=1
    echo "    found leftover data directory $DATADIR"
fi

# The start-on-login unit. It is enabled against graphical-session.target, so it has
# to be disabled before the file goes, otherwise a dangling symlink is left in
# graphical-session.target.wants and systemd complains about it at every login.
UNIT="$HOME/.config/systemd/user/nzxt-cam.service"
UNIT_FOUND=0
if [ -f "$UNIT" ]; then
    UNIT_FOUND=1; FOUND=1
    echo "    found start-on-login unit: $UNIT"
fi

# The udev rule that grants access to the cooler. Keyed on the file name the install
# writes, so a rule of the user's own -- or one liquidctl or OpenRGB installed under
# its own name -- is left exactly where it is.
UDEV_RULE="/etc/udev/rules.d/60-nzxt-cam.rules"
UDEV_FOUND=0
if [ -f "$UDEV_RULE" ] && grep -qs 'idVendor}=="1e71"' "$UDEV_RULE"; then
    UDEV_FOUND=1; FOUND=1
    echo "    found udev rule: $UDEV_RULE"
fi

if [ "$FOUND" -eq 0 ]; then
    say "Nothing to remove -- no prefix, launcher or menu entries found."
    exit 0
fi

# ----------------------------------------------------------------------- confirm

say "This will remove"
[ "$PREFIX_OK" -eq 1 ] && echo "    $PREFIX   (CAM, its settings, profiles and logs)"
[ -f "$LAUNCHER" ]     && echo "    $LAUNCHER"
for f in "$LAUNCHER"-*; do [ -e "$f" ] && echo "    $f"; done
[ -d "$DATADIR" ] && echo "    $DATADIR   (CAM's own copy of Wine)"
[ "$UNIT_FOUND" -eq 1 ] && echo "    $UNIT   (start on login)"
[ "$UDEV_FOUND" -eq 1 ] && echo "    $UDEV_RULE   (device access; needs root)"
[ "$RUNNING" -gt 0 ] 2>/dev/null && echo "    $RUNNING running launcher process(es) will be stopped"
for f in "${DESKTOP_DIRS[@]:-}";  do [ -n "$f" ] && echo "    $f/   (whole directory)"; done
for f in "${DESKTOP_ITEMS[@]:-}"; do [ -n "$f" ] && echo "    $f"; done
echo
confirm "    Go ahead?" || die "aborted, nothing was removed"

# ------------------------------------------------------------------------ remove

# Stop it first, so Restart=on-failure cannot put the launcher back while the prefix is
# being deleted out from under it. The unit file itself goes further down, after the
# launcher is dead -- see below for why deleting it here does not stick.
if [ "$UNIT_FOUND" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    say "Turning off start on login"
    systemctl --user disable --now nzxt-cam.service >/dev/null 2>&1 || true
fi

# The launcher's scripts go before the launcher does, which looks backwards and is not.
# On the way out it mirrors CAM's "start with Windows" switch back onto the Linux side,
# and the prefix -- with that switch still set in it -- is still here at this point. Kill
# it with nzxt-cam-autostart still on disk and its dying act is to write the unit back
# and enable it, after which nothing removes it again. Deleting a running script is
# harmless: the shell already has it open.
if [ -f "$LAUNCHER" ] || compgen -G "$LAUNCHER"'*' >/dev/null 2>&1; then
    say "Removing the launcher"
    # The launcher and its helpers all share the nzxt-cam prefix, so take them by
    # pattern rather than by a list that would go stale as helpers are added.
    for f in "$LAUNCHER" "$LAUNCHER"-*; do
        [ -e "$f" ] && rm -f "$f" && echo "    $f"
    done
fi

if [ "$RUNNING" -gt 0 ] 2>/dev/null; then
    say "Stopping the launcher"
    for pid in $(launcher_pids); do kill "$pid" 2>/dev/null || true; done
    sleep 2
    for pid in $(launcher_pids); do kill -9 "$pid" 2>/dev/null || true; done
fi

# Now that nothing is left to re-arm it.
if [ "$UNIT_FOUND" -eq 1 ]; then
    say "Removing the start-on-login unit"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable nzxt-cam.service >/dev/null 2>&1 || true
    fi
    rm -f "$UNIT" && echo "    $UNIT"
    command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

if [ "$PREFIX_OK" -eq 1 ]; then
    say "Stopping anything still running in the prefix"
    WINEPREFIX="$PREFIX" wineserver -k >/dev/null 2>&1 || true
    sleep 2

    say "Removing the prefix"
    rm -rf "$PREFIX"
    # Take ~/pfx with it, but only when we were the only thing in it.
    parent="$(dirname "$PREFIX")"
    if [ "$parent" != "$HOME" ] && [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
        rmdir "$parent" && echo "    also removed empty $parent"
    fi
fi

if [ "$TREE_FOUND" -eq 1 ] || [ -d "$DATADIR" ]; then
    say "Removing CAM's copy of Wine"
    [ -d "$WINETREE" ] && rm -rf "$WINETREE" && echo "    $WINETREE"
    # The stashed copy of the patched drivers sits beside it, so the directory never
    # emptied and both were left behind.
    [ -d "$DATADIR" ] && rm -rf "$DATADIR" && echo "    $DATADIR"
fi

if [ ${#DESKTOP_DIRS[@]} -gt 0 ] || [ ${#DESKTOP_ITEMS[@]} -gt 0 ]; then
    say "Removing menu entries and icons"
    for f in "${DESKTOP_DIRS[@]:-}";  do [ -n "$f" ] && rm -rf "$f" && echo "    $f/"; done
    for f in "${DESKTOP_ITEMS[@]:-}"; do [ -n "$f" ] && rm -f  "$f" && echo "    $f"; done
    # Wine's own menu directories, only if CAM was the last thing in them.
    for d in "$HOME/.local/share/applications/wine/Programs" \
             "$HOME/.local/share/applications/wine"; do
        [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null)" ] && rmdir "$d" && echo "    $d (empty)"
    done
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
fi

if [ "$UDEV_FOUND" -eq 1 ]; then
    say "Removing the udev rule"
    if ! command -v sudo >/dev/null 2>&1; then
        warn "sudo not found -- remove it by hand: rm $UDEV_RULE"
    elif sudo rm -f "$UDEV_RULE"; then
        echo "    $UDEV_RULE"
        sudo udevadm control --reload-rules >/dev/null 2>&1 || true
        sudo udevadm trigger --subsystem-match=hidraw --subsystem-match=usb >/dev/null 2>&1 || true
    else
        warn "could not remove $UDEV_RULE -- remove it by hand."
    fi
fi

say "Done"
echo "    NZXT CAM has been removed."
echo
echo "    Reinstall any time with:"
echo "      curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash"

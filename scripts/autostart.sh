#!/usr/bin/env bash
# Add or remove a desktop autostart entry for NZXT CAM.
#
#   scripts/autostart.sh          add the entry
#   scripts/autostart.sh remove   take it away again
#
# A desktop entry rather than a systemd user unit: CAM is a GUI application, and an
# autostart entry runs inside the desktop session, where DISPLAY/WAYLAND_DISPLAY and
# the rest of the session environment already exist. A user unit can start before the
# session is up and has to have that environment imported into it.
#
# CAM's own "start with Windows" setting cannot do this. It writes to the prefix's
# HKCU\...\CurrentVersion\Run key, which Wine only acts on when a Wine session starts
# -- and nothing starts one when you log in to Linux, so the switch never fires.
set -euo pipefail

ENTRY="$HOME/.config/autostart/nzxt-cam.desktop"
LAUNCHER="$HOME/.local/bin/nzxt-cam"

case "${1:-add}" in
    remove|--remove|-r)
        if [ -f "$ENTRY" ]; then
            rm -f "$ENTRY"
            echo "removed $ENTRY"
        else
            echo "not installed: $ENTRY"
        fi
        ;;
    add|--add|"")
        [ -x "$LAUNCHER" ] || {
            echo "launcher not found at $LAUNCHER -- install CAM first" >&2; exit 1; }
        # Use the icon Wine's menu builder generated, if it made one. Its name is
        # not predictable, so look it up rather than guess and end up with a blank.
        icon="$(find "$HOME/.local/share/icons" -name "*NZXT CAM*.png" -print -quit 2>/dev/null)"
        icon="$(basename "${icon%.png}" 2>/dev/null)"

        mkdir -p "$(dirname "$ENTRY")"
        {
            echo "[Desktop Entry]"
            echo "Type=Application"
            echo "Name=NZXT CAM"
            echo "Comment=Start NZXT CAM under Wine when you log in"
            echo "Exec=$LAUNCHER"
            [ -n "$icon" ] && echo "Icon=$icon"
            echo "Terminal=false"
            echo "X-GNOME-Autostart-enabled=true"
        } > "$ENTRY"
        echo "installed $ENTRY"
        ;;
    *)
        echo "usage: $(basename "$0") [add|remove]" >&2
        exit 1
        ;;
esac

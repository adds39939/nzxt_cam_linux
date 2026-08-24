#!/usr/bin/env bash
# Point the menu and desktop shortcuts at the launcher instead of at Wine.
#
#   desktop-entries.sh [prefix] [launcher]
#
# Wine's menu builder generates a .desktop for CAM that runs `wine <the .lnk>`
# directly. That starts CAM with none of the things the launcher does for it: no GPU
# poller, so every GPU reading sits at n/a; no device fixups, so the cooler goes
# missing after a Wine restart; no capture-card guard and no crash supervisor, so one
# click on that page leaves the app blank for good.
#
# Worse, CAM is not single-instance under Wine -- launching it twice really does give
# two of them, both driving the same cooler. So the shortcut is rewritten rather than
# left as a second, quieter way to start the app.
#
# Rewriting is safe: Wine only regenerates these when it processes the .lnk again, on
# an install or a prefix update, not on an ordinary start. The launcher re-runs this
# each time it starts, which picks up any that a CAM update recreated.
set -euo pipefail

PREFIX="${1:-${WINEPREFIX:-$HOME/pfx/nzxt_cam}}"
LAUNCHER="${2:-$HOME/.local/bin/nzxt-cam}"
quiet="${NZXT_CAM_QUIET:-}"

say() { [ -n "$quiet" ] || echo "$@"; }

[ -x "$LAUNCHER" ] || { say "no launcher at $LAUNCHER"; exit 0; }

changed=0
for dir in "$HOME/.local/share/applications" "$HOME/Desktop" "$HOME/.config/autostart"; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' f; do
        # Ours only: the entry has to name this prefix, so a second prefix's CAM (or
        # somebody else's Wine app) is left alone.
        grep -q -F -e "WINEPREFIX=$PREFIX" -e "Path=$PREFIX" "$f" 2>/dev/null || continue
        # ...and actually start CAM, rather than being one of Wine's file-association
        # entries that merely mention the prefix.
        grep -qi -e 'Exec=.*NZXT CAM\.lnk' -e 'Exec=.*NZXT CAM\.exe' "$f" 2>/dev/null || continue

        # Keep the icon, the name and StartupWMClass -- that last one is what lets the
        # desktop match CAM's window to this entry, so the taskbar shows the icon
        # rather than a generic Wine one. Only the Exec and Path lines change.
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

if [ "$changed" = 1 ]; then
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
fi
exit 0

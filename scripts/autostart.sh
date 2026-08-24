#!/usr/bin/env bash
# Start NZXT CAM when you log in.
#
#   scripts/autostart.sh          turn it on
#   scripts/autostart.sh remove   turn it off again
#   scripts/autostart.sh status   say which of the two is in use, and whether it is on
#   scripts/autostart.sh sync     follow CAM's own "start with Windows" switch
#
# A systemd user unit rather than an XDG autostart entry, where the session has one.
# The unit is ordered after graphical-session.target, so it starts once DISPLAY and
# WAYLAND_DISPLAY exist; it is PartOf that target, so logging out stops CAM instead of
# leaving it behind driving the cooler with no tray to reach it from; and it restarts
# CAM if it dies. "systemctl --user status nzxt-cam" then says what happened, which an
# autostart entry cannot: when one of those fails there is nowhere to look.
#
# Not every session drives graphical-session.target -- plain window managers often do
# not -- and there the unit would sit there never starting. So the target is checked
# for rather than assumed, and an autostart entry is written instead where it is
# missing. Only ever one of the two is installed.
#
# CAM's own "start with Windows" switch cannot do any of this by itself. It writes to
# the prefix's HKCU\...\CurrentVersion\Run key, which Wine only acts on when a Wine
# session starts -- and nothing starts one when you log in to Linux, so the switch
# never fires. "sync" gives it its meaning back: the launcher runs it as it starts and
# again as it stops, and whichever way the switch has been left is mirrored onto the
# Linux side. Both, so that flipping the switch and logging straight out still works --
# the stop side reads the registry after the wineserver has flushed it.
set -euo pipefail

LAUNCHER="$HOME/.local/bin/nzxt-cam"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/nzxt-cam.service"
ENTRY="$HOME/.config/autostart/nzxt-cam.desktop"

# Which prefix? The launcher records it, so prefer that over guessing.
PREFIX="${WINEPREFIX:-}"
if [ -z "$PREFIX" ] && [ -f "$LAUNCHER" ]; then
    PREFIX="$(sed -n 's/^export WINEPREFIX="\(.*\)"$/\1/p' "$LAUNCHER" | head -1)"
fi
PREFIX="${PREFIX:-$HOME/pfx/nzxt_cam}"

quiet=""
say() { [ -n "$quiet" ] || echo "$@"; }

# systemd only if this session actually reaches the target the unit hangs off. It is
# running now, so if it is active now it will be active at the next login too.
use_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user show-environment >/dev/null 2>&1 || return 1
    systemctl --user is-active graphical-session.target >/dev/null 2>&1
}

# ------------------------------------------------------------------ the two backends

install_systemd() {
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=NZXT CAM
Documentation=https://github.com/adds39939/nzxt_cam_linux
# CAM is a tray application: it needs the session's DISPLAY/WAYLAND_DISPLAY, which
# only exist once the session is up, and it should go when the session goes.
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
# --startup is the argument CAM puts in the Run key for itself, so a login start looks
# to it exactly like one on Windows. Whether the window appears or CAM goes straight to
# the tray is its own "Start minimized" setting, not this flag.
ExecStart=$LAUNCHER --startup

# Wine's output must not go to the journal. It writes a fixme line for every stub it
# hits, hundreds of them in the first seconds, and journald's socket buffer fills
# faster than it drains -- at which point the write blocks and CAM hangs half way
# through starting, with one process, no window, and nothing in any log to say why.
# The same file the launcher uses when it is detached, so there is one place to look.
StandardOutput=append:$PREFIX/nzxt-cam.log
StandardError=append:$PREFIX/nzxt-cam.log

# SIGTERM to the launcher only, not to every wine process at once: the launcher stops
# CAM and then the wineserver, in that order, which is the difference between a clean
# shutdown and thirty seconds of systemd waiting before it resorts to SIGKILL.
KillMode=mixed
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=graphical-session.target
UNIT_EOF
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable nzxt-cam.service >/dev/null 2>&1 ||
        { echo "could not enable nzxt-cam.service" >&2; return 1; }
    say "enabled $UNIT"
}

remove_systemd() {
    # "disable", never "disable --now": the launcher calls this through "sync", and
    # stopping the unit there would be CAM killing itself moments after it started.
    # Not starting next time is what was asked for, not quitting now.
    command -v systemctl >/dev/null 2>&1 &&
        systemctl --user disable nzxt-cam.service >/dev/null 2>&1 || true
    if [ -f "$UNIT" ]; then
        rm -f "$UNIT"
        command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 || true
        say "removed $UNIT"
        return 0
    fi
    return 1
}

install_entry() {
    # Use the icon Wine's menu builder generated, if it made one. Its name is not
    # predictable, so look it up rather than guess and end up with a blank.
    local icon
    icon="$(find "$HOME/.local/share/icons" -name "*NZXT CAM*.png" -print -quit 2>/dev/null)"
    icon="$(basename "${icon%.png}" 2>/dev/null)"

    mkdir -p "$(dirname "$ENTRY")"
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=NZXT CAM"
        echo "Comment=Start NZXT CAM under Wine when you log in"
        echo "Exec=$LAUNCHER --startup"
        [ -n "$icon" ] && echo "Icon=$icon"
        echo "Terminal=false"
        echo "X-GNOME-Autostart-enabled=true"
    } > "$ENTRY"
    say "installed $ENTRY"
}

remove_entry() {
    [ -f "$ENTRY" ] || return 1
    rm -f "$ENTRY"
    say "removed $ENTRY"
}

enabled() {
    if [ -f "$UNIT" ]; then
        command -v systemctl >/dev/null 2>&1 || return 0
        systemctl --user is-enabled nzxt-cam.service >/dev/null 2>&1
        return
    fi
    [ -f "$ENTRY" ]
}

# Install one backend and make sure the other is not left behind alongside it.
turn_on() {
    [ -x "$LAUNCHER" ] || { echo "launcher not found at $LAUNCHER -- install CAM first" >&2; exit 1; }
    if use_systemd && install_systemd; then
        remove_entry >/dev/null 2>&1 || true
    else
        install_entry
        remove_systemd >/dev/null 2>&1 || true
    fi
}

turn_off() {
    local gone=1
    remove_systemd && gone=0
    remove_entry   && gone=0
    [ "$gone" = 0 ] || say "not installed"
}

# ---------------------------------------------------------------- CAM's own switch

# Wine writes the key with its backslashes doubled, so match on the literal text
# rather than build a regex out of it. Only the Run section counts: the same value
# name turns up under RunOnce and in the machine hive.
runkey_set() {
    [ -f "$PREFIX/user.reg" ] || return 1
    awk '
        /^\[/            { in_run = (index($0, "CurrentVersion\\\\Run]") > 0) }
        in_run && index($0, "\"NZXT.CAM\"=") == 1 { found = 1 }
        END              { exit !found }
    ' "$PREFIX/user.reg"
}

# Write the switch back the other way, so CAM's settings screen agrees with what the
# session will actually do. Skipped when there is no prefix to write to yet.
set_runkey() {
    [ -d "$PREFIX" ] || return 0
    command -v wine >/dev/null 2>&1 || return 0
    local key='HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
    if [ "$1" = on ]; then
        WINEPREFIX="$PREFIX" wine reg add "$key" /v NZXT.CAM /t REG_SZ \
            /d 'C:\Program Files\NZXT CAM\NZXT CAM.exe --startup' /f >/dev/null 2>&1 || true
    else
        WINEPREFIX="$PREFIX" wine reg delete "$key" /v NZXT.CAM /f >/dev/null 2>&1 || true
    fi
}

case "${1:-add}" in
    add|--add|"")
        turn_on
        set_runkey on
        ;;
    remove|--remove|-r)
        turn_off
        set_runkey off
        ;;
    sync)
        # The launcher's hook. Registry is the source of truth here, so this never
        # writes back to it -- it only makes the Linux side match.
        quiet=1
        if runkey_set; then
            enabled || turn_on
        else
            enabled && turn_off || true
        fi
        ;;
    status)
        if [ -f "$UNIT" ]; then
            echo "start on login: on   (systemd user unit $UNIT)"
            systemctl --user is-enabled nzxt-cam.service 2>/dev/null | sed 's/^/    systemctl: /'
        elif [ -f "$ENTRY" ]; then
            echo "start on login: on   (autostart entry $ENTRY)"
        else
            echo "start on login: off"
        fi
        runkey_set && echo "    CAM's own \"start with Windows\" switch: on" \
                   || echo "    CAM's own \"start with Windows\" switch: off"
        ;;
    *)
        echo "usage: $(basename "$0") [add|remove|status|sync]" >&2
        exit 1
        ;;
esac

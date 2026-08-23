#!/usr/bin/env bash
# One-shot installer for NZXT CAM under Wine.
#
#   curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash
#
# Downloads the CAM installer, creates a patched Wine prefix and installs a launcher.
# Everything it needs is fetched from the repo; nothing has to be cloned by hand.
#
# Non-interactive use (CI, unattended):
#   WINEPREFIX=~/pfx/nzxt_cam ASSUME_YES=1 bash install.sh
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/adds39939/nzxt_cam_linux.git}"
CAM_URL="${CAM_URL:-https://nzxt-app.nzxt.com/NZXT-CAM-Setup.exe}"
DEFAULT_PREFIX="$HOME/pfx/nzxt_cam"

say()  { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# When piped from curl, stdin is the script itself -- prompts must come from the
# terminal. Fall back to defaults when there is no terminal at all.
if [ -r /dev/tty ] && [ -t 1 ]; then TTY=/dev/tty; else TTY=""; fi
ask() {                      # ask <prompt> <default>
    local prompt="$1" default="$2" reply=""
    if [ -z "$TTY" ] || [ -n "${ASSUME_YES:-}" ]; then printf '%s' "$default"; return; fi
    read -r -p "$prompt [$default]: " reply < "$TTY" || reply=""
    printf '%s' "${reply:-$default}"
}
confirm() {                  # confirm <prompt>   -> 0 yes / 1 no
    local reply=""
    if [ -n "${ASSUME_YES:-}" ]; then return 0; fi
    if [ -z "$TTY" ]; then return 1; fi
    read -r -p "$1 [y/N]: " reply < "$TTY" || reply=""
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- dependencies

say "Checking dependencies"
MISSING=()
for c in wine winetricks cabextract curl; do
    command -v "$c" >/dev/null || MISSING+=("$c")
done
command -v git >/dev/null || command -v tar >/dev/null || MISSING+=("git or tar")
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing: ${MISSING[*]}" >&2
    echo >&2
    echo "  Arch:    sudo pacman -S --needed wine winetricks cabextract curl git" >&2
    echo "  Debian:  sudo apt install wine winetricks cabextract curl git" >&2
    echo "  Fedora:  sudo dnf install wine winetricks cabextract curl git" >&2
    die "install the packages above and re-run"
fi

WINEVER="$(wine --version)"
echo "    wine: $WINEVER"
case "$WINEVER" in
    wine-11.*) ;;
    *) warn "prebuilt DLLs were built against wine-11.16; on a different major version"
       warn "run scripts/build-wine-dlls.sh after this finishes" ;;
esac

# ------------------------------------------------------------------- the repo

# Use the checkout we are running from when there is one, otherwise fetch a copy.
SELF="${BASH_SOURCE[0]:-}"
REPO=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    CAND="$(cd "$(dirname "$SELF")" && pwd)"
    [ -d "$CAND/patches" ] && [ -d "$CAND/prebuilt" ] && REPO="$CAND"
fi

CLEANUP=""
if [ -z "$REPO" ]; then
    say "Fetching $REPO_URL"
    REPO="$(mktemp -d)"; CLEANUP="$REPO"
    if command -v git >/dev/null; then
        git clone --depth 1 "$REPO_URL" "$REPO" >/dev/null 2>&1 \
            || die "could not clone $REPO_URL"
    else
        curl -fsSL "${REPO_URL%.git}/archive/refs/heads/main.tar.gz" \
            | tar xz -C "$REPO" --strip-components=1 \
            || die "could not download the repository"
    fi
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
[ -f "$REPO/scripts/setup.sh" ] || die "repository looks incomplete: $REPO"

# ----------------------------------------------------------------- the prefix

say "Where should the Wine prefix live?"
echo "    This directory holds the whole Windows install; it can be deleted later."
PREFIX="$(ask "    Prefix" "${WINEPREFIX:-$DEFAULT_PREFIX}")"
PREFIX="${PREFIX/#\~/$HOME}"
echo "    Using: $PREFIX"

if [ -d "$PREFIX" ] && [ -n "$(ls -A "$PREFIX" 2>/dev/null)" ]; then
    warn "$PREFIX already exists and is not empty."
    confirm "    Reuse it (existing CAM install will be updated)?" \
        || die "aborted; re-run and choose a different prefix"
fi
mkdir -p "$PREFIX"

# -------------------------------------------------------------- the installer

DL="$(mktemp -d)"
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"; rm -rf "$DL"' EXIT
INSTALLER="$DL/NZXT-CAM-Setup.exe"

say "Downloading NZXT CAM"
curl -# -L -o "$INSTALLER" "$CAM_URL" || die "download failed: $CAM_URL"
[ -s "$INSTALLER" ] || die "downloaded installer is empty"
case "$(head -c2 "$INSTALLER")" in
    MZ) ;;
    *)  die "downloaded file is not a Windows executable -- did the URL change?" ;;
esac
echo "    $(du -h "$INSTALLER" | cut -f1)  $INSTALLER"

# ------------------------------------------------------------------ the build

say "Installing (this takes a few minutes)"
WINEPREFIX="$PREFIX" bash "$REPO/scripts/setup.sh" "$INSTALLER"

# ----------------------------------------------------------------- the drivers

# hidclass.sys and wineusb.sys are kernel drivers: Wine loads them from its own
# install directory, not from the prefix, so they cannot be overridden per-prefix.
say "Kernel drivers"
echo "    Two patched drivers must be installed system-wide for the cooler to be"
echo "    detected. This needs root, and a wine package upgrade overwrites them."
if confirm "    Install them now with sudo?"; then
    sudo bash "$REPO/scripts/install-wine-drivers.sh" || warn "driver install failed"
    WINEPREFIX="$PREFIX" wineserver -k 2>/dev/null || true
else
    echo
    echo "    Skipped. Run this later, or the cooler will not appear:"
    echo "      sudo $REPO/scripts/install-wine-drivers.sh"
    [ -n "$CLEANUP" ] && echo "      (clone the repo first -- this copy is temporary)"
fi

say "Done"
echo "    Launch with:  nzxt-cam"
echo
echo "    If ~/.local/bin is not on your PATH, add it:"
echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
echo
echo "    The window scale follows your desktop. Override it with:"
echo "      NZXT_CAM_SCALE=1.5 nzxt-cam"

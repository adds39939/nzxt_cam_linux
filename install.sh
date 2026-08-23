#!/usr/bin/env bash
# One-shot installer for NZXT CAM under Wine.
#
#   curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash
#
# Downloads the CAM installer and the latest release (which carries the patched Wine
# binaries, already built), creates a patched Wine prefix and installs a launcher.
# Nothing has to be cloned or compiled by hand.
#
# Non-interactive use (CI, unattended):
#   WINEPREFIX=~/pfx/nzxt_cam ASSUME_YES=1 bash install.sh
set -euo pipefail

RELEASE_TARBALL="${RELEASE_TARBALL:-https://github.com/adds39939/nzxt_cam_linux/releases/latest/download/nzxt-cam-linux.tar.gz}"
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
command -v tar >/dev/null || MISSING+=("tar")
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing: ${MISSING[*]}" >&2
    echo >&2
    echo "  Arch:    sudo pacman -S --needed wine winetricks cabextract curl tar" >&2
    echo "  Debian:  sudo apt install wine winetricks cabextract curl tar" >&2
    echo "  Fedora:  sudo dnf install wine winetricks cabextract curl tar" >&2
    die "install the packages above and re-run"
fi

# Sensor readings come from Linux. CPU needs nothing extra (kernel hwmon/cpufreq);
# the GPU needs nvidia-smi, which is optional -- without it CAM still detects the GPU
# and everything else works, its readings just stay n/a.
if ls /sys/bus/pci/devices/*/vendor >/dev/null 2>&1 &&
   grep -qx 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null &&
   ! command -v nvidia-smi >/dev/null 2>&1; then
    warn "NVIDIA GPU found but nvidia-smi is missing -- GPU readings will show n/a."
    warn "  Arch: nvidia-utils   Debian/Ubuntu: nvidia-utils-<version>   Fedora: xorg-x11-drv-nvidia-cuda"
fi

echo "    wine: $(wine --version)"

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
    # The patched Wine binaries are not kept in the repository -- they are built by CI
    # and attached to each release, so take the release rather than a checkout.
    say "Fetching the latest release"
    REPO="$(mktemp -d)"; CLEANUP="$REPO"
    curl -fsSL "$RELEASE_TARBALL" | tar xz -C "$REPO" --strip-components=1 \
        || die "could not download $RELEASE_TARBALL"
fi
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
[ -f "$REPO/scripts/setup.sh" ] || die "release looks incomplete: $REPO"
[ -d "$REPO/prebuilt" ] || die "release has no prebuilt/ -- build it with scripts/build-wine-dlls.sh"

# The binaries are built against one Wine version; warn if this machine differs.
BUILT="$(cat "$REPO/prebuilt/BUILT_AGAINST" 2>/dev/null || cat "$REPO/WINE_VERSION" 2>/dev/null || echo unknown)"
case "$(wine --version)" in
    "wine-$BUILT"*) ;;
    *) warn "these binaries were built against wine-$BUILT, you have $(wine --version)."
       warn "if anything misbehaves, rebuild with: $REPO/scripts/build-wine-dlls.sh" ;;
esac

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
    echo "    Skipped. The cooler will not appear until they are installed."
    if [ -n "$CLEANUP" ]; then
        echo "    This copy is temporary, so re-run the installer when you are ready:"
        echo "      curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash"
    else
        echo "      sudo $REPO/scripts/install-wine-drivers.sh"
    fi
fi

say "Done"
echo "    Launch with:  nzxt-cam"
echo
echo "    If ~/.local/bin is not on your PATH, add it:"
echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
echo
echo "    The window scale follows your desktop. Override it with:"
echo "      NZXT_CAM_SCALE=1.5 nzxt-cam"

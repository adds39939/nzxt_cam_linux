#!/usr/bin/env bash
# Set up NZXT CAM under Wine.
# Usage: scripts/setup.sh /path/to/NZXT-CAM-Setup.exe
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WINEPREFIX:-$HOME/pfx/nzxt_cam}"
INSTALLER="${1:-}"

say() { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for c in wine winetricks cabextract; do
  command -v "$c" >/dev/null || die "missing dependency: $c"
done

WINEVER="$(wine --version)"
say "Wine: $WINEVER   Prefix: $WINEPREFIX"
case "$WINEVER" in
  wine-11.*) ;;
  *) echo "WARNING: prebuilt DLLs were built against wine-11.16." >&2
     echo "         On a different major version, rebuild: scripts/build-wine-dlls.sh" >&2 ;;
esac

say "Creating prefix (64-bit)"
WINEARCH=win64 wineboot -i >/dev/null 2>&1 || true
wineserver -w

# --- THE critical fix: without real fonts Chromium renders zero-height text and
# --- the renderer dies on a NOTREACHED. Everything else is secondary.
if [ ! -f "$WINEPREFIX/drive_c/windows/Fonts/arial.ttf" ]; then
  say "Installing corefonts (required — see README)"
  winetricks -q corefonts
else
  say "corefonts already installed"
fi

say "Installing patched Wine DLLs into the prefix"
SYS="$WINEPREFIX/drive_c/windows/system32"
for d in propsys windows.devices.enumeration cfgmgr32 winusb wintypes setupapi; do
  [ -f "$SYS/$d.dll" ] && [ ! -f "$SYS/$d.dll.stock-backup" ] && cp "$SYS/$d.dll" "$SYS/$d.dll.stock-backup"
  cp "$REPO/prebuilt/$d.dll" "$SYS/$d.dll"
  wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /t REG_SZ /d native /f >/dev/null 2>&1
done
cp "$REPO/prebuilt/usbtree-fixup.exe" "$SYS/usbtree-fixup.exe"
wineserver -w

if [ -n "$INSTALLER" ]; then
  [ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
  say "Running the CAM installer (this takes a few minutes)"
  wine "$INSTALLER" || true
  wineserver -w
fi

CAMDIR="$WINEPREFIX/drive_c/Program Files/NZXT CAM"
[ -d "$CAMDIR" ] || die "CAM is not installed. Re-run with the installer path."

say "Setting guest mode (skips the sign-in screen)"
DS="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/NZXT CAM/DataStorage/latest/local"
mkdir -p "$DS"
printf '{"mode":"guest"}\n' > "$DS/currentUser.json"
printf '{"pathname":"/"}\n' > "$DS/router.json"

say "Installing launcher -> ~/.local/bin/nzxt-cam"
mkdir -p "$HOME/.local/bin"
sed "s|__PREFIX__|$WINEPREFIX|" "$REPO/scripts/nzxt-cam.in" > "$HOME/.local/bin/nzxt-cam"
chmod +x "$HOME/.local/bin/nzxt-cam"

say "Done. Run:  nzxt-cam"

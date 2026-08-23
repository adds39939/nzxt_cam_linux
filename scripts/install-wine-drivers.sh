#!/usr/bin/env bash
# Install the patched Wine kernel drivers SYSTEM-WIDE (needs root).
#
# Why root: Wine loads builtin *drivers* from its install dir, not from the prefix.
# Unlike the user-mode DLLs, a driver cannot be overridden per-prefix -- marking one
# "native" makes winehid fail with STATUS_DLL_INIT_FAILED and breaks all HID.
#
#   hidclass.sys  publishes DEVPKEY_DeviceInterface_HID_* on HID interfaces
#   wineusb.sys   registers GUID_DEVINTERFACE_USB_DEVICE so USB devices are enumerable
#
# Both changes are additive and standards-conforming; other applications are unaffected.
# A wine package upgrade overwrites them -- re-run this script afterwards.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTDIR="${DESTDIR:-/usr/lib/wine/x86_64-windows}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
[ -d "$DESTDIR" ] || { echo "not found: $DESTDIR -- set DESTDIR=/path/to/x86_64-windows" >&2; exit 1; }

WINEVER="$(sudo -u "${SUDO_USER:-$USER}" wine --version 2>/dev/null || echo unknown)"
BUILT="$(cat "$REPO/prebuilt/BUILT_AGAINST" 2>/dev/null || echo unknown)"
[ "$WINEVER" = "wine-$BUILT" ] || {
  echo "WARNING: wine is $WINEVER but drivers were built against $BUILT." >&2
  echo "         Rebuild with scripts/build-wine-dlls.sh before installing." >&2; }

for drv in hidclass.sys wineusb.sys; do
  SRC="$REPO/prebuilt/$drv"; DEST="$DESTDIR/$drv"
  [ -f "$SRC" ]  || { echo "missing $SRC" >&2; exit 1; }
  [ -f "$DEST" ] || { echo "not found: $DEST" >&2; exit 1; }
  [ -f "$DEST.stock-backup" ] || { cp -a "$DEST" "$DEST.stock-backup"; echo "backed up -> $DEST.stock-backup"; }
  install -m644 "$SRC" "$DEST"
  echo "installed $drv"
done
echo
echo "Now restart wine:  WINEPREFIX=~/pfx/nzxt_cam wineserver -k"

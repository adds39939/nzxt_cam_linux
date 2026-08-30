#!/usr/bin/env bash
# Install the patched Wine kernel drivers into CAM's private Wine tree.
#
#   scripts/install-wine-drivers.sh          into the private tree (no root)
#   DESTDIR=/usr/lib/wine/x86_64-windows sudo scripts/install-wine-drivers.sh
#                                            the old system-wide way, if you insist
#
#   hidclass.sys  publishes DEVPKEY_DeviceInterface_HID_* on HID interfaces
#   wineusb.sys   registers GUID_DEVINTERFACE_USB_DEVICE so USB devices are enumerable
#   explorer.exe  names each tray icon window after the application that owns it
#
# These cannot be applied per prefix -- Wine takes the .sys inside a prefix as a marker
# that the driver exists and maps the bytes from its own install directory, by name.
# That used to mean root, and a `pacman -Syu` silently undoing it. It now means writing
# into the copy of Wine under $HOME that wine-tree.sh made, which no package manager
# will touch. See scripts/wine-tree.sh for how that was established.
#
# Both changes are additive and standards-conforming; other applications are unaffected.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TREE="${NZXT_CAM_WINE_TREE:-$HOME/.local/share/nzxt-cam/wine}"
DESTDIR="${DESTDIR:-$TREE/lib/wine/x86_64-windows}"
UNIXDIR="${UNIXDIR:-$TREE/lib/wine/x86_64-unix}"

[ -d "$REPO/prebuilt" ] || {
  echo "No prebuilt/ directory -- run ./scripts/build-wine-dlls.sh first," >&2
  echo "or install from a release, which ships the binaries." >&2; exit 1; }

[ -d "$DESTDIR" ] || {
  echo "not found: $DESTDIR" >&2
  echo "create the private Wine tree first:  $REPO/scripts/wine-tree.sh create" >&2
  exit 1; }

# Writing into the tree as root would leave it owned by root and unwritable next time.
if [ "$(id -u)" -eq 0 ] && [ "$DESTDIR" = "$TREE/lib/wine/x86_64-windows" ]; then
  echo "Do not run this with sudo: the private tree belongs to your user." >&2
  echo "  $REPO/scripts/install-wine-drivers.sh" >&2
  exit 1
fi

# The drivers are compiled against one Wine version; the tree records which one it was
# seeded from, so compare against that rather than whatever `wine` is on PATH now.
BUILT="$(cat "$REPO/prebuilt/BUILT_AGAINST" 2>/dev/null || cat "$REPO/WINE_VERSION" 2>/dev/null || echo unknown)"
TREEVER="$(sed -n 's/^host_wine=//p' "$TREE/.nzxt-cam-wine" 2>/dev/null || echo unknown)"
case "$TREEVER" in
  "wine-$BUILT"|"wine-$BUILT "*|"wine-$BUILT-"*|unknown) ;;
  *) echo "WARNING: the private tree holds $TREEVER but these drivers were built" >&2
     echo "         against wine-$BUILT. Rebuild with scripts/build-wine-dlls.sh." >&2 ;;
esac

# wineusb.sys has two halves: the PE driver and a Unix .so that talks to libusb. They
# share struct definitions, so BOTH must be installed together or the ABI mismatches
# and transfers fault.
if [ -f "$REPO/prebuilt/wineusb.so" ] && [ -f "$UNIXDIR/wineusb.so" ]; then
  [ -f "$UNIXDIR/wineusb.so.stock-backup" ] ||
    { cp -a "$UNIXDIR/wineusb.so" "$UNIXDIR/wineusb.so.stock-backup"; echo "backed up -> wineusb.so.stock-backup"; }
  rm -f "$UNIXDIR/wineusb.so"          # never write through a link into the host's Wine
  install -m755 "$REPO/prebuilt/wineusb.so" "$UNIXDIR/wineusb.so"
  echo "installed wineusb.so (unix half)"
fi

for drv in hidclass.sys wineusb.sys; do
  SRC="$REPO/prebuilt/$drv"; DEST="$DESTDIR/$drv"
  [ -f "$SRC" ]  || { echo "missing $SRC" >&2; exit 1; }
  [ -f "$DEST" ] || { echo "not found: $DEST" >&2; exit 1; }
  [ -f "$DEST.stock-backup" ] || { cp -a "$DEST" "$DEST.stock-backup"; echo "backed up -> $drv.stock-backup"; }
  rm -f "$DEST"
  install -m644 "$SRC" "$DEST"
  echo "installed $drv"
done

# explorer.exe owns Wine's system tray. Stock, it creates every icon window untitled,
# and a tray with no title to go on falls back to the X11 window id for the icon's
# identity -- a fresh one on every run, so "keep this icon hidden" is set against an id
# that never comes back and the icon reappears after each reboot. The patched build
# names the window after the owning executable instead.
#
# Unlike the drivers this one is cosmetic, and prebuilt sets from before it existed do
# not carry it, so a missing binary is skipped rather than fatal -- the cooler does not
# depend on it.
SRC="$REPO/prebuilt/explorer.exe"; DEST="$DESTDIR/explorer.exe"
if [ ! -f "$SRC" ]; then
  echo "skipped explorer.exe (not in prebuilt/ -- tray icons keep their old behaviour)"
elif [ ! -f "$DEST" ]; then
  echo "skipped explorer.exe (not found: $DEST)" >&2
else
  [ -f "$DEST.stock-backup" ] ||
    { cp -a "$DEST" "$DEST.stock-backup"; echo "backed up -> explorer.exe.stock-backup"; }
  rm -f "$DEST"
  install -m644 "$SRC" "$DEST"
  echo "installed explorer.exe"
fi

# Keep a copy next to the tree. Re-seeding it (after deliberately moving to a newer
# Wine, say) then puts these back by itself, instead of handing back a stock tree that
# looks fine and detects nothing.
STASH="${NZXT_CAM_DRIVER_STASH:-$HOME/.local/share/nzxt-cam/drivers}"
mkdir -p "$STASH"
for f in hidclass.sys wineusb.sys wineusb.so explorer.exe; do
  [ -f "$REPO/prebuilt/$f" ] && install -m644 "$REPO/prebuilt/$f" "$STASH/$f"
done
[ -f "$REPO/prebuilt/BUILT_AGAINST" ] && install -m644 "$REPO/prebuilt/BUILT_AGAINST" "$STASH/BUILT_AGAINST"
echo "stashed a copy in $STASH"

echo
echo "into: $DESTDIR"

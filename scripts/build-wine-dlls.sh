#!/usr/bin/env bash
# Rebuild every patched Wine component from source.
# Needed when your Wine version differs from prebuilt/BUILT_AGAINST.
# Usage: scripts/build-wine-dlls.sh [wine-version]     e.g. scripts/build-wine-dlls.sh 11.16
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${1:-$(wine --version | sed 's/^wine-//')}"
SERIES="${VER%%.*}.x"
WORK="${WORK:-$(mktemp -d)}"

command -v x86_64-w64-mingw32-gcc >/dev/null || {
  echo "Missing PE cross-compiler. Install it, e.g.:" >&2
  echo "  Arch:   sudo pacman -S --needed mingw-w64-gcc" >&2
  echo "  Debian: sudo apt install gcc-mingw-w64-x86-64" >&2
  exit 1; }

echo "==> Building Wine $VER in $WORK"
cd "$WORK"
curl -# -L -o "wine-$VER.tar.xz" "https://dl.winehq.org/wine/source/$SERIES/wine-$VER.tar.xz"
tar xf "wine-$VER.tar.xz"
cd "wine-$VER"

echo "==> Applying patches"
for p in "$REPO"/patches/*.patch; do
  echo "    $(basename "$p")"
  patch -p0 --forward < "$p"
done
[ -f include/wine/wineusb.h ] || { echo "patch series did not create include/wine/wineusb.h" >&2; exit 1; }

echo "==> configure (a few minutes)"
./configure --enable-win64 --disable-tests --without-x --without-freetype >/dev/null

# User-mode DLLs are re-linked WITHOUT -Wl,--wine-builtin: a builtin-marked DLL is
# rejected under WINEDLLOVERRIDES=...=n and nothing loads. Drivers keep the marker,
# because a "native" driver makes winehid fail with STATUS_DLL_INIT_FAILED.
relink_native() {           # $1 = dll dir, $2 = output name
  local dir="$1" out="$2"
  make -j"$(nproc)" "dlls/$dir/x86_64-windows/$out" >/dev/null
  local cmd
  cmd=$(make -n "dlls/$dir/x86_64-windows/$out" --always-make 2>/dev/null \
        | grep -m1 'winegcc -o' || true)
  if [ -z "$cmd" ]; then echo "could not recover link command for $out" >&2; exit 1; fi
  cmd=${cmd//-Wl,--wine-builtin /}
  cmd=${cmd/-o dlls\/$dir\/x86_64-windows\/$out/-o $REPO/prebuilt/$out}
  eval "$cmd"
  x86_64-w64-mingw32-strip "$REPO/prebuilt/$out"
  echo "    built $out (native)"
}

build_driver() {            # $1 = dir, $2 = output name (stays builtin)
  make -j"$(nproc)" "dlls/$1/x86_64-windows/$2" >/dev/null
  cp "dlls/$1/x86_64-windows/$2" "$REPO/prebuilt/$2"
  x86_64-w64-mingw32-strip "$REPO/prebuilt/$2"
  echo "    built $2 (builtin driver)"
}

echo "==> Building components"
relink_native propsys                      propsys.dll
relink_native windows.devices.enumeration  windows.devices.enumeration.dll
relink_native cfgmgr32                     cfgmgr32.dll
relink_native winusb                       winusb.dll
relink_native wintypes                     wintypes.dll
relink_native setupapi                     setupapi.dll
relink_native windows.devices.usb          windows.devices.usb.dll
build_driver  hidclass.sys                 hidclass.sys
build_driver  wineusb.sys                  wineusb.sys

# wineusb.sys also has a Unix half (libusb backend) sharing structs with the PE
# side; building only one of the two mismatches the ABI.
make -j"$(nproc)" dlls/wineusb.sys/wineusb.so >/dev/null
cp dlls/wineusb.sys/wineusb.so "$REPO/prebuilt/wineusb.so"
strip "$REPO/prebuilt/wineusb.so" 2>/dev/null || true
echo "    built wineusb.so (unix half)"

echo "==> Building the GPU PCI location tool"
x86_64-w64-mingw32-gcc -O1 -o "$REPO/prebuilt/gpu-pci-fixup.exe" "$REPO/tools/gpu-pci-fixup.c"
x86_64-w64-mingw32-strip "$REPO/prebuilt/gpu-pci-fixup.exe"
echo "    built gpu-pci-fixup.exe"

echo "==> Building the CPUID SDK shim"
x86_64-w64-mingw32-gcc -O1 -shared -o "$REPO/prebuilt/cpuidsdk64_shim.dll" \
  "$REPO/tools/cpuid-shim/shim.c" "$REPO/tools/cpuid-shim/thunks.S" -loleaut32
echo "    built cpuidsdk64_shim.dll"

echo "$VER" > "$REPO/prebuilt/BUILT_AGAINST"
echo
echo "==> Done. Install with:"
echo "      ./scripts/setup.sh                     # user-mode DLLs, per prefix"
echo "      sudo ./scripts/install-wine-drivers.sh # kernel drivers, system-wide"

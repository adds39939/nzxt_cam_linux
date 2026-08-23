#!/usr/bin/env bash
# Rebuild the two patched Wine DLLs from source.
# Needed when your Wine version differs from the one in prebuilt/ (see BUILT_AGAINST).
# Usage: scripts/build-wine-dlls.sh [wine-version]   e.g. scripts/build-wine-dlls.sh 11.16
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

echo "==> Building Wine $VER DLLs in $WORK"
cd "$WORK"
curl -# -L -o "wine-$VER.tar.xz" "https://dl.winehq.org/wine/source/$SERIES/wine-$VER.tar.xz"
tar xf "wine-$VER.tar.xz"
cd "wine-$VER"

echo "==> Applying patches"
patch -p0 --forward < "$REPO/patches/01-propsys-hid-properties.patch"
patch -p0 --forward < "$REPO/patches/02-devicewatcher-updated-removed.patch"

echo "==> configure (a few minutes)"
./configure --enable-win64 --disable-tests --without-x --without-freetype >/dev/null

echo "==> make"
make -j"$(nproc)" dlls/propsys/x86_64-windows/propsys.dll
make -j"$(nproc)" dlls/windows.devices.enumeration/x86_64-windows/windows.devices.enumeration.dll

# Re-link WITHOUT -Wl,--wine-builtin so Wine will accept them as "native" DLLs.
# A builtin-marked DLL is rejected under WINEDLLOVERRIDES=...=n and nothing loads.
echo "==> Re-linking as native"
tools/winegcc/winegcc -o "$REPO/prebuilt/propsys.dll" --wine-objdir . \
  --cc-cmd=x86_64-w64-mingw32-gcc -b x86_64-w64-mingw32 -shared dlls/propsys/propsys.spec \
  dlls/propsys/x86_64-windows/{propstore,propsys_main,propvar}.o \
  dlls/propsys/x86_64-windows/propsys_classes_r.res \
  dlls/ole32/x86_64-windows/libole32.a dlls/oleaut32/x86_64-windows/liboleaut32.a \
  libs/uuid/x86_64-windows/libuuid.a libs/winecrt0/x86_64-windows/libwinecrt0.a \
  libs/compiler-rt/x86_64-windows/libcompiler-rt.a dlls/ucrtbase/x86_64-windows/libucrtbase.a \
  dlls/kernel32/x86_64-windows/libkernel32.a dlls/ntdll/x86_64-windows/libntdll.a -Wl,--build-id

D=dlls/windows.devices.enumeration
tools/winegcc/winegcc -o "$REPO/prebuilt/windows.devices.enumeration.dll" --wine-objdir . \
  --cc-cmd=x86_64-w64-mingw32-gcc -b x86_64-w64-mingw32 -shared $D/windows.devices.enumeration.spec \
  $D/x86_64-windows/*.o $D/x86_64-windows/*.res \
  dlls/cfgmgr32/x86_64-windows/libcfgmgr32.a dlls/combase/x86_64-windows/libcombase.a \
  dlls/propsys/x86_64-windows/libpropsys.a \
  libs/uuid/x86_64-windows/libuuid.a libs/winecrt0/x86_64-windows/libwinecrt0.a \
  libs/compiler-rt/x86_64-windows/libcompiler-rt.a dlls/ucrtbase/x86_64-windows/libucrtbase.a \
  dlls/kernel32/x86_64-windows/libkernel32.a dlls/ntdll/x86_64-windows/libntdll.a -Wl,--build-id

x86_64-w64-mingw32-strip "$REPO/prebuilt/"*.dll
echo "$VER" > "$REPO/prebuilt/BUILT_AGAINST"
echo "==> Done. Re-run scripts/setup.sh to install them."

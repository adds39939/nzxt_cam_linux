#!/usr/bin/env bash
# Set up NZXT CAM under Wine.
# Usage: scripts/setup.sh /path/to/NZXT-CAM-Setup.exe
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WINEPREFIX:-$HOME/pfx/nzxt_cam}"
INSTALLER="${1:-}"

say() { printf '\n\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Let Wine finish what it is doing, but never wait indefinitely: "wineserver -w" waits
# for every process in the prefix to exit, so anything holding a window open -- CAM
# itself, most likely -- blocks the install for good. Give it a moment, then stop it.
settle() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 wineserver -w 2>/dev/null || wineserver -k >/dev/null 2>&1 || true
  else
    wineserver -k >/dev/null 2>&1 || true
  fi
}

for c in wine winetricks cabextract; do
  command -v "$c" >/dev/null || die "missing dependency: $c"
done

# CAM gets its own copy of Wine, seeded from this machine's, and everything from here
# runs against that rather than whatever `wine` PATH would find. The two patched kernel
# drivers can only be applied inside a Wine install directory, so this is what keeps
# them out of /usr -- no root to install, and no package upgrade to undo them.
say "Giving CAM its own copy of Wine"
bash "$REPO/scripts/wine-tree.sh" create
eval "$(bash "$REPO/scripts/wine-tree.sh" env)"

say "Installing the patched drivers and explorer into it"
bash "$REPO/scripts/install-wine-drivers.sh" | sed 's/^/    /'

WINEVER="$(wine --version)"
say "Wine: $WINEVER   Prefix: $WINEPREFIX"
case "$WINEVER" in
  wine-11.*) ;;
  *) echo "WARNING: prebuilt DLLs were built against wine-11.16." >&2
     echo "         On a different major version, rebuild: scripts/build-wine-dlls.sh" >&2 ;;
esac

say "Creating prefix (64-bit)"
WINEARCH=win64 wineboot -i >/dev/null 2>&1 || true
settle

# --- THE critical fix: without real fonts Chromium renders zero-height text and
# --- the renderer dies on a NOTREACHED. Everything else is secondary.
if [ ! -f "$WINEPREFIX/drive_c/windows/Fonts/arial.ttf" ]; then
  say "Installing corefonts (required — see README)"
  winetricks -q corefonts
else
  say "corefonts already installed"
fi

say "Installing patched Wine DLLs into the prefix"
if [ ! -d "$REPO/prebuilt" ]; then
  echo "No prebuilt/ directory -- the binaries are not kept in the repository." >&2
  echo "Either install from a release:" >&2
  echo "  curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash" >&2
  echo "or build them yourself first:" >&2
  echo "  ./scripts/build-wine-dlls.sh" >&2
  exit 1
fi

SYS="$WINEPREFIX/drive_c/windows/system32"
for d in propsys windows.devices.enumeration windows.devices.usb cfgmgr32 winusb wintypes setupapi; do
  [ -f "$SYS/$d.dll" ] && [ ! -f "$SYS/$d.dll.stock-backup" ] && cp "$SYS/$d.dll" "$SYS/$d.dll.stock-backup"
  cp "$REPO/prebuilt/$d.dll" "$SYS/$d.dll"
  wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /t REG_SZ /d native /f >/dev/null 2>&1
done
cp "$REPO/prebuilt/usbtree-fixup.exe" "$SYS/usbtree-fixup.exe"
cp "$REPO/prebuilt/gpu-pci-fixup.exe" "$SYS/gpu-pci-fixup.exe"

# Match Wine's DPI to the desktop scale so window chrome and dialogs are not tiny on
# a scaled display. The Electron renderer is scaled separately by the launcher.
SCALE="${NZXT_CAM_SCALE:-}"
if [ -z "$SCALE" ] && command -v kscreen-doctor >/dev/null 2>&1; then
  SCALE=$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '/Scale:/ {print $2; exit}')
fi
[ -z "$SCALE" ] && SCALE="${GDK_SCALE:-1}"
DPI=$(awk -v s="$SCALE" 'BEGIN{printf "%d", (s*96)+0.5}')
if [ "$DPI" -gt 96 ] 2>/dev/null; then
  say "Setting Wine DPI to $DPI (desktop scale $SCALE)"
  wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$DPI" /f >/dev/null 2>&1
fi
settle

if [ -n "$INSTALLER" ]; then
  [ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
  say "Running the CAM installer (this takes a few minutes)"
  # CAM's installer launches the app as its last act, so "wineserver -w" -- wait for
  # the prefix to go quiet -- never returns: it sits there until you close a window
  # you did not ask for. Run the installer in the background instead and stop the
  # prefix once CAM is on disk, whether the installer exited or is still holding it.
  wine "$INSTALLER" >/dev/null 2>&1 &
  installer=$!
  camexe="$WINEPREFIX/drive_c/Program Files/NZXT CAM/NZXT CAM.exe"

  waited=0
  while [ "$waited" -lt 900 ]; do
    if [ -f "$camexe" ]; then
      # Installed. Done as soon as the installer lets go, or as soon as it has
      # launched CAM itself -- either way there is nothing left to wait for.
      kill -0 "$installer" 2>/dev/null || break
      pgrep -f "NZXT CAM.exe" >/dev/null 2>&1 && break
    elif ! kill -0 "$installer" 2>/dev/null; then
      break                                  # exited without installing anything
    fi
    sleep 2
    waited=$((waited + 2))
  done

  sleep 3                                    # let the last writes land
  wineserver -k >/dev/null 2>&1 || true
  wait "$installer" 2>/dev/null || true
fi

CAMDIR="$WINEPREFIX/drive_c/Program Files/NZXT CAM"
[ -d "$CAMDIR" ] || die "CAM is not installed. Re-run with the installer path."

# CAM reads CPU/GPU telemetry through CPUID's cpuidsdk64.dll, which needs a ring-0
# driver that cannot work under Wine. Keep the genuine SDK next to the shim, which
# forwards to it and fills in the readings from Linux. See tools/cpuid-shim.
say "Installing the CPUID SDK shim (CPU temperature and clocks)"
CPUID="$CAMDIR/resources/app.asar.unpacked/node_modules/@nzxt/cam-core/dist/common/cpuid"
if [ -d "$CPUID" ]; then
  # Only move the original aside once, so re-running never shims the shim.
  if [ ! -f "$CPUID/cpuidsdk64_real.dll" ]; then
    cp "$CPUID/cpuidsdk64.dll" "$CPUID/cpuidsdk64_real.dll"
  fi
  cp "$REPO/prebuilt/cpuidsdk64_shim.dll" "$CPUID/cpuidsdk64.dll"
else
  echo "    WARNING: cpuid directory not found; CPU temperature will read n/a" >&2
fi

say "Setting guest mode (skips the sign-in screen)"
DS="$WINEPREFIX/drive_c/users/$USER/AppData/Roaming/NZXT CAM/DataStorage/latest/local"
mkdir -p "$DS"
printf '{"mode":"guest"}\n' > "$DS/currentUser.json"
printf '{"pathname":"/"}\n' > "$DS/router.json"

say "Installing launcher -> ~/.local/bin/nzxt-cam"
mkdir -p "$HOME/.local/bin"
WINETREE="$(bash "$REPO/scripts/wine-tree.sh" path)"
sed -e "s|__PREFIX__|$WINEPREFIX|" -e "s|__WINETREE__|$WINETREE|" \
    "$REPO/scripts/nzxt-cam.in" > "$HOME/.local/bin/nzxt-cam"
chmod +x "$HOME/.local/bin/nzxt-cam"
# The launcher runs this to keep GPU readings fresh, so it has to outlive the
# temporary copy of the release that install.sh unpacked.
install -m755 "$REPO/scripts/gpu-poll.sh" "$HOME/.local/bin/nzxt-cam-gpu-poll"
install -m755 "$REPO/scripts/desktop-entries.sh" "$HOME/.local/bin/nzxt-cam-desktop-entries"
install -m755 "$REPO/scripts/autostart.sh" "$HOME/.local/bin/nzxt-cam-autostart"
install -m755 "$REPO/scripts/wine-tree.sh" "$HOME/.local/bin/nzxt-cam-wine-tree"

# Wine's own shortcut for CAM runs it without the launcher, and so without the GPU
# poller, the device fixups or the crash guard. Point the menu entry here instead --
# and take away the desktop shortcut CAM's installer asked for, which nobody using a
# tray application needs and which this install did not offer to create.
say "Fixing up the shortcuts CAM's installer left"
"$HOME/.local/bin/nzxt-cam-desktop-entries" "$WINEPREFIX" "$HOME/.local/bin/nzxt-cam" || true

say "Done. Run:  nzxt-cam"

# NZXT CAM on Linux (Wine)

Getting **NZXT CAM 4.76.5** to actually run under Wine on Linux -- and to detect and
drive an NZXT cooler, including its LCD.

Out of the box CAM installs fine but never gets past its loading screen, and even once
it starts it sees no NZXT hardware and no sensors at all. Over twenty separate gaps
stack up behind each other. This repo works through all of them.

![CAM running under Wine](docs/dashboard.png)

CPU and GPU telemetry are read from Linux itself, so both report correctly and either
can drive the pump and fan curves or appear on the LCD:

| Cooling | Lighting |
|---|---|
| ![Cooling](docs/cooling.png) | ![Lighting](docs/lighting.png) |

Verified on Arch Linux, `wine-11.16`, NZXT CAM 4.76.5, KDE/Wayland, with an
NZXT Kraken Elite V2 (`1e71:3012`).

---

## Install

```bash
curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash
```

That downloads NZXT CAM and the latest release, asks where to put the Wine prefix
(default `~/pfx/nzxt_cam`), builds the patched prefix and installs a `nzxt-cam`
launcher. It will offer to install the two kernel drivers with `sudo` -- without those
the cooler is not detected.

The patched Wine binaries are **not kept in this repository**. They are built from
source by [`.github/workflows/release.yaml`](.github/workflows/release.yaml) on every
push to `main` and attached to a release, which is what the installer downloads. So
nothing is compiled on your machine, and nothing opaque is committed here.

Then:

```bash
nzxt-cam
```

You need `wine`, `winetricks`, `cabextract`, `curl` and `tar` first:

```bash
sudo pacman -S --needed wine winetricks cabextract curl tar   # Arch
sudo apt install wine winetricks cabextract curl tar          # Debian/Ubuntu
sudo dnf install wine winetricks cabextract curl tar          # Fedora
```

### Sensors

CAM's own sensor drivers cannot work under Wine, so the readings are taken from Linux
instead. What that needs:

* **CPU temperature and clock** -- nothing extra. They come from the kernel's `hwmon`
  and `cpufreq` interfaces (`k10temp` on AMD, `coretemp` on Intel), which are built in.
  `lm_sensors` is **not** required.
* **GPU temperature, clock and load** -- `nvidia-smi`, which ships with the NVIDIA
  driver:

```bash
sudo pacman -S nvidia-utils                  # Arch
sudo apt install nvidia-utils-<version>      # Debian/Ubuntu, match your driver
sudo dnf install xorg-x11-drv-nvidia-cuda    # Fedora
```

Without `nvidia-smi` the GPU is still detected and everything else keeps working --
its readings just stay `n/a`. AMD and Intel GPUs are not wired up yet.

### From a clone

A clone has no `prebuilt/`, so either let `install.sh` pull the release as usual:

```bash
git clone https://github.com/adds39939/nzxt_cam_linux
cd nzxt_cam_linux
./install.sh                    # fetches the release for the binaries
```

or build them yourself, which needs a PE cross-compiler and Wine's build
dependencies:

```bash
./scripts/build-wine-dlls.sh    # builds everything into prebuilt/ (takes a while)
./scripts/setup.sh ~/Downloads/NZXT-CAM-Setup.exe
sudo ./scripts/install-wine-drivers.sh
```

Once `prebuilt/` exists, `install.sh` uses your local build rather than the release.
Already installed CAM? Omit the installer path and `setup.sh` will just apply the fixes.
The prefix defaults to `~/pfx/nzxt_cam`; override with `WINEPREFIX=... ./scripts/setup.sh`.

### Display scaling

CAM renders at 100% no matter what the desktop is set to, so on a scaled display it
comes out small. `setup.sh` reads your desktop scale (KDE via `kscreen-doctor`, else
`GDK_SCALE`) and sets Wine's DPI to match; Chromium picks that up as its device pixel
ratio. Change it at any time with:

```bash
NZXT_CAM_SCALE=1.5 nzxt-cam
```

**Do not scale it with `--force-device-scale-factor`.** It sizes the window correctly,
but it also stops cam-core from starting, so no NZXT device is ever detected — the UI
looks completely normal while Cooling and Lighting stay empty and `cam.log` is empty:

```
--force-device-scale-factor=1.25   cam.log = 0 bytes,  device not detected
Wine DPI (LogPixels) = 120         cam.log = 4600,     device detected, DPR 1.25
```

---

## Uninstall

```bash
curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/uninstall.sh | bash
```

That removes the Wine prefix -- CAM itself, its settings, profiles and logs all live
inside it -- along with the launcher and the menu entries and icons Wine created. It
then offers to put Wine's stock drivers back, which needs `sudo`; the installer kept
copies of the originals for exactly that.

It works out which prefix to remove by reading it back out of the launcher, so a
non-default `WINEPREFIX` is handled without being told. Nothing is deleted before it
has shown you the list and asked, and it will only ever delete a directory that really
is a Wine prefix.

```bash
ASSUME_YES=1 bash uninstall.sh      # unattended
KEEP_DRIVERS=1 bash uninstall.sh    # leave the patched Wine drivers in place
```

## What works

* ✅ **Kraken Elite V2 detected** (`1e71:3012`) and driven over WinUSB
* ✅ **Pump and fan curves** applied and persisted
* ✅ **LCD** -- live frames pushed to the display
* ✅ **Liquid temperature, pump and fan RPM**
* ✅ **CPU temperature, clock and load**, plus model, codename and socket
* ✅ **GPU detected**, with **temperature, clock and load**
* ✅ **CPU and GPU temperature** selectable as pump/fan curve sources, and on the LCD
* ✅ **Per-channel RGB lighting** on the cooler and its fans
* ✅ RAM usage, network throughput and the per-process table
* ✅ Every page renders, and the window follows your desktop's scaling

## Untested

* ❓ **Firmware update.** CAM ships this as separate binaries (`firmware-update.exe`,
  `rvclib-fw-updater.exe`), so it likely exercises paths none of this work touched.
  Nothing here has ever written firmware to a cooler.
* ❓ **Any NZXT device other than a Kraken Elite V2.** The discovery work is generic
  rather than model-specific, so other coolers and RGB controllers may well work --
  but none have been tried.

## To implement

* 🔧 **GPU fan speed.** CAM's field is RPM and `nvidia-smi` only exposes a percentage
  (`fan.speed.rpm` is not a queryable field), so it is left blank rather than shown in
  the wrong unit.
* 🔧 **AMD and Intel GPUs.** GPU readings come from `nvidia-smi`; nothing reads the
  equivalent AMD or Intel interfaces yet.
* 🔧 **Motherboard fan speeds and temperatures.** These need a second NZXT driver
  (`cam_driver_mb.sys`) talking to a Super-I/O chip.
* 🔧 **The rest of `Windows.Devices.Usb`.** Everything the LCD needs is implemented;
  `SendControlOutTransferAsync`, interrupt pipes and the descriptor accessors are still
  stubs, because nothing in CAM's path calls them.

## Won't implement

* 🚫 **Capture Card.** The page kills CAM's renderer under Wine (`0xC0000409`): it
  needs a COM class Wine does not implement. Since CAM restores the last page on launch
  and gives up after two crashes, one click used to leave the app blank permanently.
  The launcher now guards it from both sides -- it resets that route before starting,
  and watches for CAM's own crash-threshold message so a click during the session
  restarts the app on the dashboard by itself. Making capture *work* is out of scope.

## Wine version compatibility

Releases are built against the version in [`WINE_VERSION`](WINE_VERSION) (currently
`11.16`), and `install.sh` warns if yours differs. On a different Wine version,
rebuild against your own:

```bash
./scripts/build-wine-dlls.sh $(wine --version | sed s/^wine-//)
./scripts/setup.sh                    # reinstall them
```

Needs a PE cross-compiler (`mingw-w64-gcc` on Arch, `gcc-mingw-w64-x86-64` on Debian)
and Wine's build dependencies (`flex`, `bison`, `libusb-1.0-0-dev`).

Most of the Wine changes are small and upstream-shaped — worth filing at
[WineHQ Bugzilla](https://bugs.winehq.org/). They are not CAM-specific: they affect
any application that enumerates devices through `Windows.Devices.Enumeration`, uses
WinUSB, or asks cfgmgr32 for a device node's properties.

## Troubleshooting

**"NZXT CAM can not start while cam_helper.exe is running"** — orphaned helpers:

```bash
WINEPREFIX=~/pfx/nzxt_cam wineserver -k
```

**Still no text** — confirm corefonts landed:

```bash
ls ~/pfx/nzxt_cam/drive_c/windows/Fonts/arial.ttf
```

**Inspect the live UI** (very useful — bypasses compositor/screenshot issues):

```bash
nzxt-cam --remote-debugging-port=9222
curl -s http://127.0.0.1:9222/json    # then drive it over CDP
```

**Logs:** `~/pfx/nzxt_cam/drive_c/users/$USER/AppData/Roaming/NZXT CAM/logs/`
(`main.log`, `renderer.log`, `cam.log`, `cam_helper.log`).

**Undo everything:** see [Uninstall](#uninstall) above. `setup.sh` also leaves
`.stock-backup` copies of the DLLs it replaces in the prefix's `system32`, but those
go with the prefix.

## Kernel drivers need root

`hidclass.sys` and `wineusb.sys` are drivers. Wine loads builtin drivers from its
install directory, not the prefix, and a driver **cannot** be overridden per-prefix —
marking one `native` makes `winehid` fail with `STATUS_DLL_INIT_FAILED` and breaks all
HID. Install them with:

```bash
sudo ./scripts/install-wine-drivers.sh
```

Re-run it after any `wine` package upgrade, which overwrites them.

## The USB device tree

CAM correlates a HID interface with its WinUSB sibling by walking up to the USB hub
and port. On Windows the composite device is the parent of its interfaces:

```
USB\VID_1E71&PID_3012\512&258&3&4          composite, Address = hub port
  ├── …&MI_00\512&258&3&4                   vendor interface (WinUSB)
  └── …&MI_01\258&1F6494820E40092C&0&0&0    HID interface
        └── HID\VID_1E71&PID_3012&MI_01\…
```

Wine's tree is **flat**. `wineusb` (libusb) and `winebus` (udev) enumerate the same
physical device independently and parent every node straight to their own synthetic
root, so walking up from a HID interface reaches `ROOT\WINE\WINEBUS` and stops —
never finding a USB device node or a port number.

`tools/usbtree-fixup.c` does what `usbccgp` does on Windows: it re-points every USB
interface node's `DEVPKEY_Device_Parent` at the matching composite, publishes the
composite's children, and fills in `DEVPKEY_Device_Address` from the port number Wine
already encodes in the composite's instance ID (`usbver&revision&busnum&portnum`, so
`512&258&3&4` means bus 3, port 4).

It is not a driver change because the two buses cannot name each other's devnodes:
`winebus`'s `device_desc` has no bus/port/bcdDevice fields, so it cannot construct
`wineusb`'s composite instance ID without an ABI change across its unixlib. Doing the
join once in userspace, from data both sides already publish, is smaller and does not
fork the driver interface.

Wine's PnP manager rewrites `DEVPKEY_Device_Parent` every time the server starts, so
the fixup has to run **after** enumeration and **before** CAM — which is what the
`nzxt-cam` launcher does. Run it by hand with `-v` to see what it changes:

```bash
wine ~/.../system32/usbtree-fixup.exe -v
```

## Notes

- CAM auto-updates. Updates replace `app.asar` but **not** the Wine DLLs, fonts, or
  guest-mode setting, so they survive. Set `skipUpdateOnStart` in `settings.json` to pin.
- No patch to `app.asar` is needed.
- `privateMode` is on by default — CAM won't phone home with telemetry.
- What each Wine patch fixes, and why, is written up in [`docs/wine-fixes.md`](docs/wine-fixes.md).

## Licensing

This repository's scripts, patches and docs are MIT (see `LICENSE`).

The binaries in each release's `prebuilt/` are compiled from patched Wine sources and
are therefore **LGPL-2.1-or-later** derivative works of Wine — see `NOTICE` for the
corresponding-source pointers and rebuild instructions. They are built by CI from the
patches in this repository, and are not committed here.

No NZXT code or assets are redistributed here; get CAM from NZXT. This project
is unaffiliated with NZXT.

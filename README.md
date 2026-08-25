<div align="center">

<img src="docs/nzxt-cam.png" alt="" width="104" height="104">

<h1>NZXT CAM on Linux</h1>

**NZXT CAM via Wine** — the official app, running on Linux, driving your NZXT hardware directly.

[![Release](https://img.shields.io/github/v/release/adds39939/nzxt_cam_linux?style=flat-square&color=51007A&labelColor=1c1c1e)](https://github.com/adds39939/nzxt_cam_linux/releases/latest)
[![CAM](https://img.shields.io/badge/CAM-4.76.5-51007A?style=flat-square&labelColor=1c1c1e)](https://nzxt.com/camsoftware)
[![Wine](https://img.shields.io/badge/wine-11.16-51007A?style=flat-square&labelColor=1c1c1e)](WINE_VERSION)
[![Platform](https://img.shields.io/badge/Linux-51007A?style=flat-square&labelColor=1c1c1e&label=runs%20on)](#install)
[![License](https://img.shields.io/badge/license-MIT%20%2B%20LGPL--2.1-6b7280?style=flat-square&labelColor=1c1c1e)](#licensing)

[**Install**](#install) · [GPU readings](#gpu-readings) · [Start on login](#start-on-login) · [What works](#what-works) · [Build it yourself](#building-it-yourself) · [Troubleshooting](docs/troubleshooting.md)

</div>

<br>

Out of the box CAM never leaves its loading screen under Wine. This repository carries
the patches that get it past that, and the sensor plumbing that makes its readings
real — nothing inside a Wine prefix can see your hardware on its own.

![CAM running under Wine](docs/dashboard.png)

<sub>**The dashboard** — CPU and GPU telemetry taken from Linux's own `hwmon` and DRM
interfaces and handed to CAM through a shimmed CPUID SDK, because the ring-0 driver it
normally reads them with cannot work under Wine.</sub>

| Cooling | Lighting |
| --- | --- |
| ![Cooling](docs/cooling.png) | ![Lighting](docs/lighting.png) |

<sub>Either sensor can drive the pump and fan curves, or appear on the cooler's LCD.</sub>

Verified on Arch Linux, `wine-11.16`, KDE/Wayland, with an NZXT Kraken Elite V2
(`1e71:3012`).

---

## Install

You need `wine`, `winetricks`, `cabextract`, `curl` and `tar` first:

```bash
sudo pacman -S --needed wine winetricks cabextract curl tar   # Arch
sudo apt install wine winetricks cabextract curl tar          # Debian/Ubuntu
sudo dnf install wine winetricks cabextract curl tar          # Fedora
```

Then:

```bash
curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/install.sh | bash
```

That downloads NZXT CAM, asks where to put the Wine prefix (default `~/pfx/nzxt_cam`),
builds the patched prefix and installs a `nzxt-cam` launcher. It offers to install two
copy of Wine to keep its two patched drivers in, and to start CAM when you log in.
Nothing needs root.

Start it with:

```bash
nzxt-cam        # supervised, attached to the current terminal
nzxt-cam -d     # detached
```

The application-menu entry runs that same launcher. Starting CAM any other way skips
the GPU poller and the device fix-ups it applies, which shows up as GPU readings stuck
at `n/a` and, after a Wine restart, no cooler.

Nothing is put on your desktop. CAM's installer asks Wine for a desktop shortcut and
Wine duly makes one; the install deletes it, along with the `.lnk` it was generated
from so that it does not come back.

Starting CAM while it is already running raises the window it is showing — including
out of the tray — rather than giving you a second copy of it.

### CAM's own copy of Wine

The install puts a copy of this machine's Wine in `~/.local/share/nzxt-cam/wine` and
runs CAM against that, not the distro's. It costs about 1 GB.

That is where the two patched kernel drivers go. They cannot be applied per prefix: the
`.sys` inside a prefix is only a marker saying the driver exists, and the bytes Wine
maps come from its own install directory, looked up by name. Put them in `/usr/lib/wine`
and they need root — and the next `pacman -Syu` quietly replaces them, after which the
cooler stops being detected with nothing to say why. In `$HOME` no package manager can
reach them, and the Wine underneath CAM stops moving.

The copy is seeded from your Wine, so it starts as whatever version you have and is
then pinned to it. If that version is not the one the binaries were built against, the
installer says so and asks before going ahead. Upgrading your system `wine` afterwards
changes nothing for CAM; to move it forward deliberately:

```bash
nzxt-cam-wine-tree create      # re-seed from the current system wine
nzxt-cam-wine-tree version     # what it holds now
```

Set `NZXT_CAM_WINE_TRIM=1` when creating it to leave out Gecko and Mono, which CAM has
no use for, saving about 440 MB.

### GPU readings

These come from the kernel's own `hwmon` and DRM interfaces, so **AMD, Intel and
nouveau need nothing installed**. CPU readings likewise; `lm_sensors` is **not**
required.

NVIDIA's proprietary driver is the one exception — it registers no `hwmon` node and
exposes nothing useful in sysfs — so on that one the readings come from `nvidia-smi`,
which ships with the driver:

```bash
sudo pacman -S nvidia-utils                  # Arch
sudo apt install nvidia-utils-<version>      # Debian/Ubuntu, match your driver
sudo dnf install xorg-x11-drv-nvidia-cuda    # Fedora
```

Without it the GPU is still detected and everything else keeps working — its readings
just stay `n/a`.

What each driver actually gives you:

| | temp | load | clock | fan | power |
|---|---|---|---|---|---|
| AMD `amdgpu` | ✅ | ✅ | ✅ | ✅ RPM | ✅ |
| Intel `i915`/`xe` | ✅ | — | ✅ | ✅ RPM | ✅ |
| NVIDIA proprietary | ✅ | ✅ | ✅ | — | ✅ |
| NVIDIA `nouveau` | ✅ | — | — | ✅ RPM | — |

Intel load needs the perf PMU rather than sysfs, and NVIDIA only reports fan as a
percentage where CAM's field is RPM, so those stay `n/a` rather than show a number
that is not what it claims to be. **Only the NVIDIA path has been tested on
hardware** — the others are built on the documented sysfs interfaces but nobody has
run them.

### Start on login

CAM's own *start with Windows* switch controls this, and the installer offers it too.
Either way you end up with a systemd user unit:

```bash
nzxt-cam-autostart status     # on or off, and which mechanism
nzxt-cam-autostart add        # or remove
systemctl --user status nzxt-cam
```

The switch inside CAM cannot fire on its own here — it writes to the prefix's `Run`
key, and nothing starts a Wine session when you log in to Linux — so the launcher
mirrors it onto the systemd unit, once as it starts and again as it stops. Flip it in
either place and the other follows; flipping it and logging straight out works too,
because the stop side reads the key after Wine has flushed it to disk.

A user unit rather than an autostart entry: it is ordered after
`graphical-session.target`, so it starts once the session's `DISPLAY` exists; logging
out stops CAM rather than leaving it behind driving the cooler; it restarts CAM if it
dies; and `systemctl --user status nzxt-cam` says what happened when it does not
start. Sessions that do not drive `graphical-session.target` — plain window managers,
mostly — get an autostart entry at `~/.config/autostart/nzxt-cam.desktop` instead.

CAM's **Start minimized** setting pairs well with this if you would rather it went
straight to the tray.

### Display scaling

CAM always renders at 100%, so on a scaled display it comes out small. The installer
matches Wine's DPI to your desktop scale. Override it at any time:

```bash
NZXT_CAM_SCALE=1.5 nzxt-cam
```

## Uninstall

```bash
curl -L https://raw.githubusercontent.com/adds39939/nzxt_cam_linux/main/uninstall.sh | bash
```

That removes the Wine prefix — CAM, its settings, profiles and logs all live inside it
— along with the launcher, the start-on-login unit, and the menu entries and icons
Wine created, and CAM's copy of Wine. If an older version of this installer patched
your system Wine, it offers to put the stock drivers back, which needs `sudo`.

Something not working? See [`docs/troubleshooting.md`](docs/troubleshooting.md).

## What works

* ✅ **Kraken Elite V2 detected** (`1e71:3012`) and driven over WinUSB
* ✅ **Pump and fan curves**, applied and persisted
* ✅ **LCD** — live frames pushed to the display
* ✅ **Liquid temperature, pump and fan RPM**
* ✅ **CPU and GPU temperature, clock and load**, selectable as curve sources and on
  the LCD
* ✅ **Per-channel RGB lighting** on the cooler and its fans
* ✅ RAM usage, network throughput and the per-process table
* ✅ Every page renders, and the window follows your desktop's scaling

## Untested

* ❓ **Any NZXT device other than a Kraken Elite V2.** The work is generic rather than
  model-specific, so other coolers and RGB controllers may well work — but none have
  been tried.
* ❓ **Firmware update.** CAM ships this as separate binaries, so it likely exercises
  paths none of this work touched. Nothing here has ever written firmware to a cooler.

## What doesn't

* 🔧 **Motherboard fan speeds and temperatures** are not implemented. **GPU fan
  speed** and **Intel GPU load** are reported where the driver exposes them — see
  the table above for what each one gives.
* 🚫 **Capture Card** needs a COM class Wine does not implement, and the page kills
  CAM's renderer. The launcher recovers from it automatically, so a click no longer
  leaves the app stuck — but making capture work is out of scope.

## Notes

* CAM auto-updates. Updates replace `app.asar` but not the Wine DLLs, fonts or
  settings, so they survive. Set `skipUpdateOnStart` in `settings.json` to pin.
* `privateMode` is on by default — CAM won't phone home with telemetry.
* No patch to `app.asar` is needed.
* What each Wine patch fixes, and why, is written up in
  [`docs/wine-fixes.md`](docs/wine-fixes.md).

## Building it yourself

A clone has no `prebuilt/`, so either let `install.sh` pull the release as usual:

```bash
git clone https://github.com/adds39939/nzxt_cam_linux
cd nzxt_cam_linux
./install.sh                    # fetches the release for the binaries
```

or build them, which needs a PE cross-compiler (`mingw-w64-gcc` on Arch,
`gcc-mingw-w64-x86-64` on Debian) and Wine's build dependencies (`flex`, `bison`,
`libusb-1.0-0-dev`):

```bash
./scripts/build-wine-dlls.sh    # builds everything into prebuilt/ (takes a while)
./scripts/setup.sh ~/Downloads/NZXT-CAM-Setup.exe
```

`setup.sh` makes the private Wine tree and puts the drivers in it, so there is no
`sudo` step.

Once `prebuilt/` exists, `install.sh` uses your local build rather than the release.
If CAM is already installed, omit the installer path and `setup.sh` just applies the
fixes. The prefix defaults to `~/pfx/nzxt_cam`; override with `WINEPREFIX=...`.

Releases are built against the Wine version in [`WINE_VERSION`](WINE_VERSION)
(currently `11.16`), and `install.sh` warns if yours differs. To rebuild against your
own:

```bash
./scripts/build-wine-dlls.sh $(wine --version | sed s/^wine-//)
./scripts/setup.sh                    # reinstall them
```

None of the Wine changes are CAM-specific. They fix gaps that affect any application
that enumerates devices through `Windows.Devices.Enumeration`, uses WinUSB, or asks
cfgmgr32 for a device node's properties.

## Licensing

This repository's scripts, patches and docs are MIT (see `LICENSE`).

The binaries in each release's `prebuilt/` are compiled from patched Wine sources and
are therefore **LGPL-2.1-or-later** derivative works of Wine — see `NOTICE` for the
corresponding-source pointers and rebuild instructions. They are built by CI from the
patches in this repository, and are not committed here.

No NZXT code is redistributed here — get CAM from NZXT. The CAM icon at the top of
this page and the screenshots below it are NZXT's artwork, reproduced only to identify
the software this project patches. "NZXT" and "CAM" are NZXT's trademarks; this project
is unaffiliated with NZXT and not endorsed by it.

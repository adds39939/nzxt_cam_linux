<div align="center">

<img src="docs/nzxt-tux.png" alt="" width="104" height="104">

<h1>NZXT CAM on Linux</h1>

**NZXT CAM via Wine** — the official app, running on Linux, driving your NZXT hardware directly.

[![Release](https://img.shields.io/github/v/release/adds39939/nzxt_cam_linux?style=flat-square&color=51007A&labelColor=1c1c1e)](https://github.com/adds39939/nzxt_cam_linux/releases/latest)
[![CAM](https://img.shields.io/badge/CAM-4.76.5-51007A?style=flat-square&labelColor=1c1c1e)](https://nzxt.com/camsoftware)
[![Wine](https://img.shields.io/badge/wine-11.16%20(bundled)-51007A?style=flat-square&labelColor=1c1c1e)](WINE_VERSION)
[![License](https://img.shields.io/badge/license-MIT%20%2B%20LGPL--2.1-6b7280?style=flat-square&labelColor=1c1c1e)](#licensing)

[**Install**](#install) · [GPU readings](#gpu-readings) · [Start on login](#start-on-login) · [What works](#what-works) · [Build it yourself](#building-it-yourself) · [Troubleshooting](docs/troubleshooting.md)

</div>

<br>

This repository contains the Wine patches and the sensor plumbing that make NZXT CAM work
on Linux: the patches so it detects and drives your cooler, and the plumbing so its
temperatures, clocks and fan speeds are read from Linux itself.

<div align="center">
  
[![Download](https://img.shields.io/badge/Download-flatpak-51007A?style=for-the-badge&labelColor=1c1c1e&logo=flatpak&logoColor=white)](https://github.com/adds39939/nzxt_cam_linux/releases/latest)

</div>

<br>

![CAM running under Wine](docs/dashboard.png)

<sub>**The dashboard** — CPU and GPU telemetry taken from Linux's own `hwmon` and DRM
interfaces and handed to CAM through a shimmed CPUID SDK, because the ring-0 driver it
normally reads them with cannot work under Wine.</sub>

| Cooling | Lighting |
| --- | --- |
| ![Cooling](docs/cooling.png) | ![Lighting](docs/lighting.png) |

<sub>Either sensor can drive the pump and fan curves, or appear on the cooler's LCD.</sub>

---

## Install

**1. Install the Flatpak.** Download `nzxt-cam-linux.flatpak` from [the latest
release](https://github.com/adds39939/nzxt_cam_linux/releases/latest), then:

```bash
flatpak install --user nzxt-cam-linux.flatpak
```

**2. Install the udev rule.** This is the one step that needs root, and one you cannot skip.

NZXT devices stay owned by `root` until a udev rule says otherwise — without this CAM starts and shows no devices.

```bash
flatpak run --command=nzxt-cam-setup io.github.adds39939.NzxtCamLinux --udev-rule \
  | sudo tee /etc/udev/rules.d/60-nzxt-cam.rules >/dev/null

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw --subsystem-match=usb
```

**3. Start it**, from your application menu or with:

```bash
flatpak run io.github.adds39939.NzxtCamLinux
```

The first run downloads NZXT CAM from NZXT and installs it into the bundled Wine prefix.

### Where everything lives

Everything the app writes is in one directory,
`~/.var/app/io.github.adds39939.NzxtCamLinux/`: the Wine prefix, and with it CAM, its
settings, profiles and logs.

## Uninstall

```bash
flatpak uninstall --delete-data io.github.adds39939.NzxtCamLinux
```

## GPU readings

These come from the kernel's own `hwmon` and DRM interfaces, which are visible inside
the flatpak sandbox.

NVIDIA's proprietary driver registers no `hwmon` node and exposes nothing useful in
sysfs, so readings come from NVML — `libnvidia-ml.so.1` — which is bundled with the Flatpak.

What each driver actually gives you:

| | temp | load | clock | fan | power |
|---|---|---|---|---|---|
| AMD `amdgpu` | ✅ | ✅ | ✅ | ✅ RPM | ✅ |
| Intel `i915`/`xe` | ✅ | — | ✅ | ✅ RPM | ✅ |
| NVIDIA proprietary | ✅ | ✅ | ✅ | — | ✅ |
| NVIDIA `nouveau` | ✅ | — | — | ✅ RPM | — |

Intel load needs the perf PMU rather than sysfs, and NVIDIA only reports fan as a
percentage where CAM's field is RPM, so those stay `n/a` rather than show a number that
is not what it claims to be.

## Start on login

CAM's own *start with Windows* switch controls this:

```bash
flatpak run --command=nzxt-cam-autostart io.github.adds39939.NzxtCamLinux status
flatpak run --command=nzxt-cam-autostart io.github.adds39939.NzxtCamLinux add     # or remove
```

CAM's **Start minimized** setting pairs well with this if you would rather it went
straight to the tray.

## Display scaling

CAM always renders at 100%, so on a scaled display it comes out small. The launcher
matches Wine's DPI to your desktop's automatically. If it guesses wrong, set it:

```bash
flatpak override --user --env=NZXT_CAM_SCALE=1.5 io.github.adds39939.NzxtCamLinux
```

```bash
flatpak run --command=nzxt-cam-xdpi io.github.adds39939.NzxtCamLinux   # what it detected
```

## The system tray on KDE

CAM shows two tray entries on Plasma. Only one is CAM's; the other is Plasma's
*Background Apps* indicator, which it shows for any Flatpak running in the background.
Keep whichever you prefer. To drop CAM's and leave Plasma's:

```bash
flatpak override --user --env=NZXT_CAM_TRAY=0 io.github.adds39939.NzxtCamLinux
```

To keep CAM's — it is the one with CAM's menu on it — set the other to *Never show
(disabled)* in *Configure System Tray → Entries*.
[`docs/troubleshooting.md`](docs/troubleshooting.md) has how to tell them apart.

## What works

* ✅ **Kraken Elite V2 detected** (`1e71:3012`) and driven over WinUSB
* ✅ **Pump and fan curves**, applied and persisted
* ✅ **LCD** — live frames pushed to the display
* ✅ **Liquid temperature, pump and fan RPM**
* ✅ **CPU and GPU temperature, clock and load**, selectable as curve sources and on
  the LCD
* ✅ **Per-channel RGB lighting** on the cooler and its fans
* ✅ RAM usage, network throughput and the per-process table
* ✅ LCD Display Web Integration

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

* Custom LCD images are read from `~/Pictures`, which is the only part of your home
  directory the sandbox can see. Point CAM at `Z:\home\<you>\Pictures`.
* Repairing an install without reinstalling the Flatpak:
  `flatpak run --command=nzxt-cam-setup io.github.adds39939.NzxtCamLinux --reinstall`
* What each Wine patch fixes, and why, is written up in
  [`docs/wine-fixes.md`](docs/wine-fixes.md).

## Building it yourself

```bash
flatpak install -y flathub org.freedesktop.Platform//25.08 \
    org.freedesktop.Sdk//25.08 org.freedesktop.Sdk.Extension.mingw-w64//25.08

flatpak-builder --user --install --force-clean \
    build-dir flatpak/io.github.adds39939.NzxtCamLinux.yml
```

That downloads Wine, applies every patch in `patches/`, builds it against the
mingw-w64 SDK extension, builds the three small Windows tools in `tools/`, and installs
the result. It takes a while — most of it is Wine. Nothing else has to be installed:
the runtime and the SDK carry the compilers and the libraries.

To build against a different Wine, change the `url` and `sha256` in the manifest's
`wine` module and put the same version in [`WINE_VERSION`](WINE_VERSION) — CI checks
the two agree. Whether the patches still apply is the interesting part; they are `-p0`
patches against the tree as upstream ships it.

None of the Wine changes are CAM-specific. They fix gaps that affect any application
that enumerates devices through `Windows.Devices.Enumeration`, uses WinUSB, or asks
cfgmgr32 for a device node's properties.

## Licensing

This repository's scripts, patches, manifest and docs are MIT (see `LICENSE`).

The Wine inside each release's Flatpak bundle is compiled from patched Wine sources and
is therefore an **LGPL-2.1-or-later** derivative work of Wine — see `NOTICE` for the
corresponding-source pointers. It is built by CI from the manifest and the patches in
this repository, and no binaries are committed here.

No NZXT code is redistributed here — the app downloads CAM from NZXT. The logo at the
top of this page puts Tux (by Larry Ewing, made with GIMP) into NZXT's wordmark; it and
the screenshots below it use NZXT's artwork only to identify the software this project
patches. "NZXT" and "CAM" are NZXT's trademarks; this project is unaffiliated with NZXT
and not endorsed by it.

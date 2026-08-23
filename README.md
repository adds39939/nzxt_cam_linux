# NZXT CAM on Linux (Wine)

Getting **NZXT CAM 4.76.5** to actually run under Wine on Linux.

Out of the box CAM installs fine but never gets past its loading screen. Four
separate problems stack up behind each other. This repo fixes all of them.

![CAM running under Wine](docs/dashboard.png)

Verified on Arch Linux, `wine-11.16`, NZXT CAM 4.76.5, KDE/Wayland.

---

## Quick start

```bash
sudo pacman -S --needed wine winetricks cabextract     # Arch
git clone <this repo> ~/dev/repos/nzxt_cam_linux
cd ~/dev/repos/nzxt_cam_linux
./scripts/setup.sh ~/Downloads/NZXT-CAM-Setup.exe
nzxt-cam
```

Already installed CAM? Omit the installer path and `setup.sh` will just apply the fixes.

The prefix defaults to `~/pfx/nzxt_cam`; override with `WINEPREFIX=... ./scripts/setup.sh`.

---

## What works / what doesn't

| Works | Doesn't |
|---|---|
| UI, navigation, all pages | CPU / motherboard **temperatures** |
| CPU load %, clock | Motherboard **fan** speeds and control |
| RAM usage | **GPU** monitoring (`No supported graphics cards`) |
| Network throughput | Kraken **LCD** (see *Remaining work*) |
| Per-process CPU/RAM/net table | Firmware update (untested) |
| Lighting / Cooling / Audio pages render | |
| **Kraken Elite V2 detection** (`1e71:3012`) | |
| **Pump / fan curve control** on the Kraken | |

**Sensors will never work under Wine.** CAM reads them through a kernel driver
(`cpuz162`, `cam_driver_mb.sys`). Wine has no kernel driver support, so you'll see:

```
err:ntoskrnl:ZwLoadDriver failed to create driver L"...\cpuz162": c0000142
```

Temperature and Fan stay `n/a`. This is not fixable in userspace.

**NZXT device control** needs fixes #3–#15. The discovery path is not the obvious
one: CAM's device-framework v2 runs a WinRT **`DeviceWatcher`** over the *HID*
interface class, reads the vendor/product IDs from the returned
`DeviceInformation.Properties`, then walks the device tree up to the USB **hub and
port** to correlate the HID interface with its WinUSB sibling — and only then drives
the device over WinUSB. Every one of those steps hit a gap in Wine.

A Kraken Elite V2 (`1e71:3012`) is now detected and its pump/fan curve is applied:

```
arrival{device_id=0 arrival.device_type=KrakenEliteV2}: adding device
CoolingManager: Received new cooling configuration ... CurvePoint(20°C => 60.00%)
(client-v2) Set cooling config: SUCCESS
```

Discovery survives a cold start: the launcher runs `usbtree-fixup.exe` (see
*The USB device tree* below) after Wine's PnP manager has enumerated and before CAM
starts. **Not yet finished:** the LCD still reports `Could not find WinUSB endpoint`
— see *Remaining work*.

---

## The fixes

### 1. No fonts → blank window, then a renderer crash  ← the big one

**Symptom:** window renders white with no text; renderer then dies repeatedly with
`exitCode: -2147483645` (`0x80000003` STATUS_BREAKPOINT) and
`FATAL:check.cc(376)] Check failed: false. NOTREACHED`.

**Cause:** the prefix had no usable font for the families CAM asks for. Measured
live in the renderer via the Chrome DevTools Protocol:

```
Liberation Sans: 165   sans-serif: 0     <- generic families resolve to nothing
Noto Sans:       176   Segoe UI:   0
Tahoma:          162   Arial:      0
```

CAM's CSS is `"Segoe UI", sans-serif`. Both resolved to nothing, so every text node
had **height 0**, and Chromium hit a `NOTREACHED` when font fallback came up empty
while laying out the app shell.

Chromium maps `sans-serif` → Arial on Windows, so installing corefonts fixes the
generic families too.

**Fix:** `winetricks -q corefonts`.

Note: Wine's `FontSubstitutes` registry key does **not** help — that's a GDI
mechanism, and Chromium uses DirectWrite. You need the real font files.

### 2. Wine `propsys` is missing the HID property names

**Symptom:** stuck on the splash forever. `renderer.log`:

```
UnhandledRejection Error: Failed to start device resource emitter:
  Error { code: HRESULT(0x8002802B) }        # TYPE_E_ELEMENTNOTFOUND
fixme:propsys:propsys_GetPropertyDescriptionByName
  canonical_name not found L"System.DeviceInterface.Hid.VendorId"
```

**Cause:** `dlls/propsys/propsys_main.c` has a hardcoded `system_properties[]` table
containing exactly one `System.DeviceInterface.*` entry (Bluetooth). CAM asks for six
HID/WinUSB names; the lookup fails and the promise rejects.

**Fix:** `patches/01-propsys-hid-properties.patch` — adds the six entries. The
`PROPERTYKEY`s were already defined in Wine's `propkey.h`, so it's a 6-line addition.
It fixes both call sites: CAM's direct call, and Wine's own `PSGetPropertyKeyFromName`
inside the DeviceWatcher.

### 3. Wine's `DeviceWatcher.add_Removed` is an unimplemented stub

**Symptom:** after fix #2, the error code changes to `0x80004001` (`E_NOTIMPL`).

```
device_watcher_add_Added ...                          <- ok
fixme:enumeration:device_watcher_add_Removed ... stub! <- E_NOTIMPL
```

**Cause:** `dlls/windows.devices.enumeration/main.c` tracks handler lists for
`added`/`enumerated`/`stopped` but has none for `updated`/`removed`.

**Fix:** `patches/02-devicewatcher-updated-removed.patch` — adds both lists and
implements the four methods, mirroring the existing `add_Added` pattern.

### 4. CAM sits on `/splash` forever

**Cause:** CAM's `PrivateRoute` redirects every route to `/splash` while
`currentUser.isValid` is false. Its user model is a union:

```js
model("NoneUser",  {mode: literal("none")}) .volatile(() => ({isValid:false}))
model("GuestUser", {mode: literal("guest")}).volatile(() => ({isValid:true }))
```

Normally you'd click "continue without an account" — impossible when nothing renders.

**Fix:** write `{"mode":"guest"}` to
`DataStorage/latest/local/currentUser.json` (done by `setup.sh`).

---

## Why the DLLs are re-linked "native"

Wine builds its PE DLLs with `-Wl,--wine-builtin`. A DLL carrying that marker is
**rejected** when you ask Wine to load it as `native`, and you get:

```
err:module:import_dll Library propsys.dll ... not found
```

So `build-wine-dlls.sh` re-links both without that flag, and `setup.sh` registers
`HKCU\Software\Wine\DllOverrides` → `native` for each. Dropping a patched DLL into
`C:\windows\system32` alone does nothing: Wine loads builtins from
`/usr/lib/wine/x86_64-windows/`, and the copies in the prefix are only version-check
placeholders.

## Wine version compatibility

`prebuilt/` is built against the version in `prebuilt/BUILT_AGAINST` (currently
`11.16`). On a different Wine version, rebuild:

```bash
./scripts/build-wine-dlls.sh          # uses your installed wine version
./scripts/setup.sh                    # reinstall them
```

Needs a PE cross-compiler (`mingw-w64-gcc` on Arch, `gcc-mingw-w64-x86-64` on Debian).

Both patches are small and upstream-shaped — worth filing at
[WineHQ Bugzilla](https://bugs.winehq.org/); they affect any app that enumerates HID
devices through `Windows.Devices.Enumeration`.

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

**Undo everything:** delete the prefix (`rm -rf ~/pfx/nzxt_cam`) and
`~/.local/bin/nzxt-cam`. `setup.sh` also leaves `.stock-backup` copies of both
replaced DLLs in the prefix's `system32`.

## Notes

- CAM auto-updates. Updates replace `app.asar` but **not** the Wine DLLs, fonts, or
  guest-mode setting, so they survive. Set `skipUpdateOnStart` in `settings.json` to pin.
- No patch to `app.asar` is needed. CAM logs one harmless rejection
  (`[Core bug] CPU device should have CPU temperature channels`) because temps are
  unavailable; it no longer breaks the UI once fonts work.
- `privateMode` is on by default — CAM won't phone home with telemetry.

## Licensing

This repository's scripts, patches and docs are MIT (see `LICENSE`).

`prebuilt/*.dll` are compiled from patched Wine sources and are therefore
**LGPL-2.1-or-later** derivative works of Wine — see `NOTICE` for the
corresponding-source pointers and rebuild instructions.

No NZXT code or assets are redistributed here; get CAM from NZXT. This project
is unaffiliated with NZXT.


### 5. DevQuery enumerated properties from the wrong registry level

`propkey_string()` stores device-interface properties under
`Properties\{FMTID}\{PID}` (a subkey per property set, then per property ID), but
`enum_device_interface_property_keys()` called `RegEnumValueW` on `Properties`
itself and found nothing — so only 3 hardcoded properties were ever returned.

**Fix:** `patches/05-…` walks both subkey levels. Properties returned went 3 → 7.

### 6. `IDeviceInformation2` was not implemented

CAM queries every `DeviceInformation` for `IDeviceInformation2`
(`{f156a638-7997-48d9-a10c-269d46533f48}`) and discards the device on
`E_NOINTERFACE`. Upstream Wine has the interface **commented out** in
`windows.devices.enumeration.idl`.

**Fix:** `patches/06-…` declares it (with `Pairing` typed as `IInspectable*`, since
`DeviceInformationPairing` doesn't exist in Wine — the vtable layout is identical)
and implements `get_Kind`.

### 7. No USB device interfaces were registered at all

`wineusb.sys` creates PDOs but never calls `IoRegisterDeviceInterface`, so
`SetupDiEnumDeviceInterfaces(GUID_DEVINTERFACE_USB_DEVICE)` returned nothing and CAM
could not discover any NZXT device.

**Fix:** `patches/07-…` registers `GUID_DEVINTERFACE_USB_DEVICE` per device and
publishes `DEVPKEY_DeviceInterface_WinUsb_UsbVendorId`/`UsbProductId`.

### 8. `winusb.dll` was 21 stubs

With the device finally visible, CAM called `WinUsb_Initialize` — which aborted the
process with `EXCEPTION_WINE_STUB`. Only `WinUsb_Free` existed. WinUSB support does
not exist in upstream Wine.

**Fix:** `patches/08-…` implements it in two parts:

- **`wineusb.sys`** gains `IOCTL_WINEUSB_SUBMIT_URB`, a buffered device-control code
  carrying control / bulk / descriptor / reset / abort requests. Wine previously only
  exposed `IOCTL_INTERNAL_USB_SUBMIT_URB`, which user mode cannot reach. The URB is
  heap-allocated and freed on completion, which also reports the transferred length.
- **`winusb.dll`** implements `Initialize`, `QueryInterfaceSettings`, `QueryPipe`,
  `ControlTransfer`, `ReadPipe`, `WritePipe`, `GetDescriptor`, `ResetPipe`,
  `AbortPipe` and `GetAssociatedInterface` on top of it. `Initialize` caches the
  configuration descriptor; `QueryPipe` walks it to locate endpoints (this is how
  CAM finds the bulk endpoint used for the LCD).

The kernel IOCTL is deliberately a **generic passthrough**, so further work needs no
kernel changes — `winusb.dll` installs into the prefix like the other user-mode DLLs.

### 9. `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` returned nothing

CAM asks for each device's PDO name while hunting for the parent hub. SetupAPI never
implemented the property. `patches/09-…` synthesises a stable `\Device\<hash>` name
from the device instance ID.

### 10. WinUSB transfers failed with `ERROR_IO_PENDING`

CAM opens the USB device `FILE_FLAG_OVERLAPPED`, so the synchronous
`DeviceIoControl` in `winusb.dll` returned `ERROR_IO_PENDING` (997) and every
transfer was reported as a failure. `patches/10-…` waits on the overlapped result.

### 11. `IReference<UINT16>` did not exist  ← the root cause

This one silently rejected **every** device, with no error anywhere.

`wintypes` implements `IReference<T>` for BYTE, INT16, INT32, UINT32, INT64, UINT64,
boolean, FLOAT, DOUBLE, GUID, HSTRING, DateTime, TimeSpan, Point, Size and Rect —
but **not `UINT16`**. It can *create* a UInt16 property value (`CreateUInt16` exists)
but `QueryInterface` for `IReference<UInt16>` returns `E_NOINTERFACE`.

Every HID property CAM reads is UINT16:

```
System.DeviceInterface.Hid.VendorId / ProductId / UsagePage / UsageId
```

So CAM's vendor check failed on the very first property of every device, and the
device list came back empty with nothing logged. `patches/11-…` declares
`IReference<UINT16>` in `windows.foundation.idl` and implements the interface, and
wires `CreateUInt16` to the `_iref` variant so the vtable is actually populated.

### 12. `System.Devices.Children` was not a known property name

CAM requests it while walking the tree. `PSGetPropertyKeyFromName` returned
`TYPE_E_ELEMENTNOTFOUND` (0x8002802B), failing the whole query. `patches/12-…` adds
it (`DEVPKEY_Device_Children`, `{4340a6c5-…},9`).

### 13. Device *nodes* could not be queried at all

Three separate holes in `cfgmgr32`, all in `patches/13-…`:

- **`CM_Get_Child_Ex` was a stub that returned `CR_SUCCESS` without ever setting
  `*child`**, and `CM_Get_Sibling_Ex` returned `CR_FAILURE`. Callers walking the
  device tree got an uninitialised devnode. Both are now implemented on top of the
  `DEVPKEY_Device_Children` data Wine already maintains. `CM_Get_DevNode_Status_Ex`
  likewise never set its out-parameters.
- **`DevGetObjectProperties` only handled device *interfaces***; `DevObjectTypeDevice`
  fell through to a FIXME, so every devnode property query returned nothing.
- **`DEVPKEY_Device_InstanceId` returned only the trailing instance component** —
  `"0000"` instead of `"USB\ROOT_HUB30\0000"` — while `DEVPKEY_Device_Parent`
  correctly returned full IDs. Nothing walking parent→child could match the two up.

### 14. `DeviceInformation.CreateFromIdAsync` was a stub

CAM calls it to fetch the *device* object (`DeviceInformationKind_Device`) behind an
interface, which is how it reaches the hub and port. It returned `E_NOTIMPL`, so
cam-core logged `FindHubAndPortFailed` and dropped the device. `patches/14-…`
implements it for all three entry points using the existing DevQuery machinery.

### 15. Unnamed property keys were stringified in the wrong case

Property keys with no canonical name are exposed under their `{GUID} pid` string.
Wine formatted the GUID **lower-case** while Windows — and Wine's own
`PSStringFromPropertyKey` — use **upper-case**. `WindowsCompareStringOrdinal` is
case-sensitive, so `Lookup` returned `E_BOUNDS` for properties that were present in
the map:

```
key L"{A45C254E-DF1C-4EFD-8020-67D146A850E0} 16"  ->  E_BOUNDS   (PDOName)
key L"{A45C254E-DF1C-4EFD-8020-67D146A850E0} 30"  ->  E_BOUNDS   (Address / port)
```

`patches/15-…` switches to upper-case, matching both Windows and Wine's own API.

### 16. `FindAllAsync` on `IDeviceInformationStatics2` was a stub

The `DeviceInformationKind` overload returned `E_NOTIMPL`. `patches/16-…` wires it
to the same `find_all_async` worker the older overloads already use, mapping the
kind to a `DEV_OBJECT_TYPE`.

### 17. DevQuery string filters required identical buffer sizes

A filter like

```
System.Devices.DeviceInstanceId:="USB\VID_1E71&PID_3012\512&258&3&4"
```

never matched, because `devprop_filter_eval_compare` only compares two values when
`cmp_prop->BufferSize == prop->BufferSize`. A registry-backed string may or may not
count its terminator, while a comparand built from a query string always does:

```
propSize=108   cmpSize=110      (same 54 characters)
```

so the comparison was skipped entirely and the filter evaluated false. `patches/17-…`
compares string contents, ignoring a trailing terminator on either side.

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

## Remaining work

- **LCD:** still `Could not find WinUSB endpoint`, now failing as
  `Unexpected number of WinUSB devices: 0`. CAM issues two queries for a USB device
  interface; the one naming the composite works and returns 1 object, but the one
  naming the HID interface's own devnode returns 0:

  ```
  InstanceId:"USB\VID_1E71&PID_3012&MI_01\258&1F64…"  ->  0 objects
  InstanceId:"USB\VID_1E71&PID_3012\512&258&3&4"      ->  1 object
  ```

  This is the two-bus split again, one level deeper: the devnode CAM knows about is
  `winebus`'s, and the WinUSB interface belongs to `wineusb`'s separate devnode for
  the same physical interface. Fixing it means either making the two buses share a
  devnode, or mapping the interface across in `usbtree-fixup`.
- **Firmware update:** untested.
- Unrelated bug spotted while reading `dlls/wintypes/map.c`: `map_entry_clear` calls
  `IInspectable_AddRef` on the value it is about to drop, where it should `Release`.
  Left alone here because changing refcounting was not needed for this work.

## Kernel drivers need root

`hidclass.sys` and `wineusb.sys` are drivers. Wine loads builtin drivers from its
install directory, not the prefix, and a driver **cannot** be overridden per-prefix —
marking one `native` makes `winehid` fail with `STATUS_DLL_INIT_FAILED` and breaks all
HID. Install them with:

```bash
sudo ./scripts/install-wine-drivers.sh
```

Re-run it after any `wine` package upgrade, which overwrites them.

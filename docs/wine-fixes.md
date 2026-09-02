# The Wine changes

What each patch in `patches/` fixes, and why. None of this is needed to use
the repo -- it is the record of how CAM was made to work.

## Why the DLLs are re-linked "native"

Wine loads builtin DLLs from its own install directory, not from the prefix: the
copies in `C:\windows\system32` are only version-check placeholders, so dropping a
patched DLL in there does nothing at all.

The Flatpak sidesteps that entirely — `/app` **is** the install directory, and these
DLLs are built into it, so they are Wine's own builtins and nothing has to be
overridden. It is worth recording what the alternative cost, because it is the reason
this project ships a whole Wine rather than a handful of files: injecting a patched
DLL into a stock Wine means loading it as `native`, and Wine builds its PE DLLs with
`-Wl,--wine-builtin`, a marker that makes a `native` load **fail**:

```
err:module:import_dll Library propsys.dll ... not found
```

so each one had to be re-linked without that flag, copied into the prefix, and
registered under `HKCU\Software\Wine\DllOverrides` as `native`.

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
`DataStorage/latest/local/currentUser.json` (done by `scripts/nzxt-cam-setup`).

---

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

### 18. MS OS descriptors were never read, so WinUSB device interfaces went unregistered

A WinUSB device does not have to be opened through `GUID_DEVINTERFACE_USB_DEVICE`.
It publishes its own device interface GUID in a **Microsoft OS 1.0 descriptor**, and
applications open it by that GUID. Wine had no MS OS descriptor support at all.

Read straight off the Kraken over `usbdevfs`:

```
string desc 0xEE: 12 03 4d 00 53 00 46 00 54 00 31 00 30 00 30 00 a7 00
  signature='MSFT100'  vendor_code=0xa7

Extended Properties (wIndex=0x0005): total=224 count=1
  prop type=7 (REG_MULTI_SZ) name='DeviceInterfaceGUIDS'
       data='{30123011-7EE7-1125-0724-101503010819}'
```

and that is character-for-character the GUID CAM's LCD code queries for:

```
System.Devices.InterfaceClassGuid:="{30123011-7EE7-1125-0724-101503010819}"
```

`patches/18-…` makes `wineusb.sys` fetch string descriptor `0xEE`, verify the
`MSFT100` signature, take the vendor request code from its last byte, request the
Extended Properties feature descriptor, parse `DeviceInterfaceGUIDs` out of it, and
register that interface with `IoRegisterDeviceInterface`.

It registers only where WinUSB would be the function driver on Windows: on the
interfaces of a composite device rather than its parent (that one belongs to
usbccgp), and never on a HID interface, which winebus and hidclass drive. Registering
it everywhere makes CAM find three devices where it expects one.

### 19. `Windows.Devices.Usb` was entirely unimplemented

The LCD is not driven over raw WinUSB. CAM activates the **WinRT** `UsbDevice` class
and streams frames through it, and every method in Wine's `windows.devices.usb` was a
stub returning `E_NOTIMPL` — the DLL was 236 lines with no `UsbDevice` object at all.

`patches/19-…` implements the object graph the LCD path needs:

```
UsbDevice.FromIdAsync(id)          opens the interface, WinUsb_Initialize
  └── Configuration
        └── UsbInterfaces[0]
              ├── BulkOutPipes[]   -> OutputStream.WriteAsync -> WinUsb_WritePipe
              └── BulkInPipes[]    -> InputStream.ReadAsync   -> WinUsb_ReadPipe
```

Supporting pieces: the standard Wine async-operation helper (including the
`IAsyncOperationWithProgress` variants the stream methods return), a vector for the
collection properties, and `IIterable`/`IIterator` declarations added to
`windows.devices.usb.idl` — only `IVectorView` was declared, so projections that
iterate the collections could not resolve the parameterized IIDs.

Two smaller gaps fell out of it: `winusb` had no `IMPORTLIB`, so nothing could link
against it, and `wine/wineusb.h` (added by patch 8) was never listed in
`include/Makefile.in`, which breaks the build as soon as the makefiles are regenerated.

With this in place the LCD streams for real — 20-byte command headers alternating
with 1228800-byte frames, exactly 640 x 480 x 4:

```
WinUsb_WritePipe pipe 0x2, length 20
WinUsb_WritePipe pipe 0x2, length 1228800
```

### 20. CPU telemetry needs a ring-0 driver — shimmed instead

Not a Wine bug, and the only fix here that is not a Wine patch. CAM reads CPU
telemetry through CPUID's `cpuidsdk64.dll`, which drives a ring-0 helper (`cpuz162`)
to reach MSRs and the SMU. Wine cannot load it, so the SDK's init returns `0x45A`,
`cam_helper` retries five times and gives up, and CAM registers **no CPU device**.

`tools/cpuid-shim` is installed as `cpuidsdk64.dll` with the genuine SDK kept beside
it as `cpuidsdk64_real.dll`. It forwards every call to the real SDK — which still
supplies topology, model numbers, codename and socket from CPUID alone — reports init
as successful, and replaces the readings that need the driver:

| SDK call | Meaning | Source |
|---|---|---|
| `a3fd47fa` | initialise | forced to succeed, error out-params cleared |
| `602cc059` | CPU package temperature | `k10temp` / `coretemp` hwmon |
| `039a0734` | per-core clock multiplier | `cpufreq/scaling_cur_freq` |

The SDK exports exactly one symbol, `QueryInterface(uint32 name_hash)`, returning a
function pointer per hashed name; each is a thin forwarder to a C++ virtual method on
the instance. Two details make a C thunk unusable, so the call path is written in
assembly (`tools/cpuid-shim/thunks.S`):

* readings come back in **XMM0**, which a C thunk cannot forward and the logging path
  would clobber — this is why the clock first appeared as a plausible-looking but
  wrong `20475MHz`;
* several entry points take **arguments on the stack** — the sensor getter takes ten,
  six of them out-pointers — and a fixed four-argument thunk drops them, handing the
  callee wild pointers to write through.

Which call is which was found by exploiting the SDK's own convention: an unavailable
reading is returned as `-1.0f`, so the handful of getters returning exactly that are
the ones the missing driver would have filled in. Feeding each a distinct value and
reading the result off CAM's own UI identifies them without any symbol names -- the
SDK exports exactly one symbol and the hashes are computed at runtime, so there are
none to recover. `tools/cpuid-shim` can also print a hash-to-vtable-slot map by
decoding each forwarder's `jmp *disp32(%rax)` at runtime, which is how the rest of
the surface above was identified.

With the shim, `Temperature` and `Clock` read correctly and CAM offers **CPU
Temperature** next to Liquid Temperature as a pump/fan curve source and on the LCD.

### 21. Display adapters had no PCI location, so CAM skipped every GPU

CAM reported `No supported graphics cards were found` on a machine where Wine itself
identifies the card perfectly: `EnumDisplayDevicesW` returns `NVIDIA GeForce RTX 5090`
with the right `PCI\VEN_10DE&DEV_2B85` id.

The GPU is not found through DXGI (a `CreateDXGIFactory1` hook inside `index.node`
never fires, and making wined3d report a card Wine recognises changes nothing) and not
through display enumeration either. `cam_helper` walks display adapters and, for each
one, asks `CM_Get_DevNode_PropertyW` for `DEVPKEY_Device_BusNumber` and
`DEVPKEY_Device_Address`. Wine registers the GPU device node but leaves both unset, so
the first call returns `CR_NO_SUCH_VALUE`, the adapter is abandoned, and the D3DKMT
code that would query it is never even reached -- `gdi32` is never so much as loaded.

Wine's cfgmgr32 maps those two property keys onto the legacy registry values
`BusNumber` and `Address` on the device node, so no code change is needed: filling
them in is enough. `tools/gpu-pci-fixup.c` matches the PCI ids in each Windows
instance id against `/sys/bus/pci/devices` and writes the address the kernel reports
(plus `LocationInformation`). The launcher runs it before CAM starts.

With that, `cam_helper` loads `gdi32`, resolves `D3DKMTOpenAdapterFromDeviceName`,
`D3DKMTQueryAdapterInfo` and `D3DKMTQueryStatistics`, and CAM registers a **GPU**
device -- `monitoring.rs` switches from the `GPUs: none identified` warning to listing
the adapter.

### 22. GPU temperature, clock and load

With the GPU detected (fix #21) every reading still showed `n/a`, because CAM takes
GPU telemetry from the CPUID SDK, not from D3DKMT -- and the driverless SDK enumerates
no GPU. `cam_helper` walks the SDK device list, picks out devices of class `0x20`, and
attaches their sensors to the GPU records it built from D3DKMT.

The shim appends one device of that class and answers its sensor queries from Linux.
The sensor classes, identified by feeding each a distinct value and reading the result
off CAM's own UI:

| class | reading | source |
|---|---|---|
| `0x2000` | temperature | `nvmlDeviceGetTemperature` |
| `0x3000` | fan (RPM) | not served -- only a percentage is available |
| `0x5000` | power | `nvmlDeviceGetPowerUsage` |
| `0xe000` | load | `nvmlDeviceGetUtilizationRates` |
| `0xf000` | clock | `nvmlDeviceGetClockInfo` |

NVIDIA exposes no hwmon node, so the shim cannot read the GPU directly the way it
reads `k10temp`; the launcher refreshes NVML's readings into a small file instead.
(These used to come from `nvidia-smi`, which is part of the driver package and is not
in the Flatpak sandbox. `libnvidia-ml.so.1` is -- it arrives with the runtime's NVIDIA
extension -- and it is what `nvidia-smi` reads them with itself.)

One piece cannot be fixed at the Wine level, and it is worth being precise about
why. Each GPU entry `cam_helper` builds carries an SDK-linkage pair: a flag at
`+0x38`, set to 1 once the entry has been paired with a CPUID SDK GPU device, and
that device's ordinal at `+0x3c`. Before attaching readings it looks for the entry
whose flag is 1 and whose ordinal matches the class-`0x20` device it is on.

Under Wine that flag is never set. A hardware watchpoint on the field shows nothing
ever writes it, and the whole SDK-derived half of the entry (its first `0x58` bytes,
including the fan slot the pass itself later fills) stays zero. The linkage comes
from the SDK's own GPU enumeration, which cannot exist without the driver -- so
there is no missing Wine call to implement. The pairing has to come from us.

The shim therefore relaxes the flag test to accept the value the field actually has,
by changing one immediate byte, rather than deleting the branch:

```
42 83 7c 38 38 01   cmpl $0x1,0x38(%rax,%r15,1)     <- the 01 becomes 00
75 xx               jne  <next entry>
```

The ordinal comparison at `+0x3c` still runs, so entries are still paired one to one
and a second GPU cannot be handed the first one's readings -- which removing the
branch would have risked. It is found by signature and applied only on a single
unambiguous match, so a CAM update that moves the code disables the change instead
of corrupting something else.

Wine's `D3DKMTQueryAdapterInfo` does not implement `KMTQAITYPE_ADAPTERADDRESS`, and
the shim did serve it for a while. That turned out to *break* GPU detection rather
than help it -- with the hook in place CAM found no GPU at all, without it the GPU is
found and reads correctly -- so it is gone. Detection needs only the device node's
PCI location from fix #21; the readings come from the SDK, not from D3DKMT.

CAM now shows GPU temperature, clock and load, and offers **GPU Temperature** as a
pump/fan curve source and on the LCD alongside Liquid and CPU.

### 23. The Capture Card page soft-locks the app

Opening Capture Card kills the Electron renderer under Wine (exit code
`0xC0000409`, `STATUS_STACK_BUFFER_OVERRUN`). On its own that would just be a
crashed page, but CAM persists the current route in `DataStorage/.../router.json`
and restores it on the next launch -- so one click leaves the app permanently stuck
on a blank page, crash-looping until it hits its own crash threshold.

The launcher rewrites that route back to the dashboard before starting CAM, so the
app can always be recovered by relaunching it. The page itself is still fatal;
nothing here makes capture work.


### 24. The tray icon is a new application on every boot

**Symptom:** on KDE, hiding CAM's system tray icon never sticks. Every reboot puts it
back in the visible tray, and the tray's own config has grown another entry:

```
hiddenItems=...,steam,plasmashell_microphone,31457291,25165835,18874379,20971531
                                             ^^^^^^^^ one dead entry per boot
```

**Cause:** Wine's `explorer.exe` created every tray icon window with no title:

```c
CreateWindowExW( 0, tray_icon_class.lpszClassName, NULL, WS_CLIPSIBLINGS | WS_POPUP,
                 0, 0, icon_cx, icon_cy, 0, NULL, NULL, icon );
```

An X11 tray icon is an XEmbed window, and on Plasma `xembedsniproxy` wraps each one in
a StatusNotifierItem whose `Id` comes from the window title -- falling back to the raw
window id when there isn't one:

```cpp
QString SNIProxy::Title() const {
    KWindowInfo window(m_windowId, NET::WMName);    // _NET_WM_NAME
    return window.name();
}
QString SNIProxy::Id() const {
    const auto title = Title();
    // we always need /some/ ID so if no window title exists, just use the winId.
    if (title.isEmpty()) return QString::number(m_windowId);
    return title;
}
```

So the icon's identity was an X11 window id -- `0x140000B` this boot, `0x1E0000B` the
last one. Plasma was storing the preference correctly the whole time, against an id
that never comes back. Nothing about this is CAM-specific: every Wine tray icon on
every desktop that tries to remember something per-icon has the same problem.

**Fix:** patch 20 names the icon window after the executable that owns it --
`QueryFullProcessImageNameW` on the owner window's process, basename, extension
dropped -- so the window carries `_NET_WM_NAME = "NZXT CAM"` from the moment it is
created, before it docks. The tooltip would have been the obvious thing to use, but
applications rewrite it as their status changes and the id would move again.

Check what the desktop sees:

```bash
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
       org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems |
  sed 's/^as [0-9]* //' | tr -d '"' | tr ' ' '\n' | grep . |
  while read -r item; do
    busctl --user get-property "${item%%/*}" "/${item#*/}" \
           org.kde.StatusNotifierItem Id
  done
```

`s "NZXT CAM"` is the patched build; a bare number is the stock one.

Two things the patch cannot do for you. The icon arrives under its new name as an item
the tray has never seen, so **hide it once more** after installing -- that time it
sticks. And the dead numeric entries left behind are still in `hiddenItems` in
`~/.config/plasma-org.kde.plasma.desktop-appletsrc`; they do no harm, but they can be
deleted from that line by hand. Plasma reads the file at login, so log out and back in
rather than expecting the edit to take hold live.


## The USB device tree

Not a patch, but the same kind of gap. CAM correlates a HID interface with its
WinUSB sibling by walking up to the USB hub and port. On Windows the composite
device is the parent of its interfaces:

```
USB\VID_1E71&PID_3012\512&258&3&4          composite, Address = hub port
  ├── …&MI_00\512&258&3&4                   vendor interface (WinUSB)
  └── …&MI_01\258&1F6494820E40092C&0&0&0    HID interface
        └── HID\VID_1E71&PID_3012&MI_01\…
```

Wine's tree is **flat**. `wineusb` (libusb) and `winebus` (udev) enumerate the same
physical device independently and parent every node straight to their own synthetic
root, so walking up from a HID interface reaches `ROOT\WINE\WINEBUS` and stops --
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
the fixup has to run **after** enumeration and **before** CAM -- which is what the
`nzxt-cam` launcher does. Run it by hand with `-v` to see what it changes:

```bash
wine ~/.../system32/usbtree-fixup.exe -v
```

## Kernel drivers are installed system-wide

`hidclass.sys` and `wineusb.sys` are drivers. Wine loads builtin drivers from its
install directory, not the prefix, and a driver **cannot** be overridden per-prefix --
marking one `native` makes `winehid` fail with `STATUS_DLL_INIT_FAILED` and breaks all
HID.

This is the constraint the whole shape of this project follows from. Patching the
system's Wine meant `sudo`, and the next package upgrade silently putting the stock
drivers back -- the cooler would simply stop being detected. Copying Wine into `$HOME`
and patching that avoided both, at the cost of a gigabyte and a version-matching
problem. Building Wine into `/app` and shipping it as a Flatpak is the same idea
carried to its conclusion: the install directory is part of the application, written
once at build time, and nothing on the host can reach it.

The patched `explorer.exe` from fix 24 travels with them. It is not a driver and could
in principle be overridden per prefix, but it is loaded from the same install directory
for the same reason.

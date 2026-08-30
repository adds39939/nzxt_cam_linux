# Troubleshooting

**"NZXT CAM can not start while cam_helper.exe is running"** — an orphaned helper is
still alive. Kill the prefix's Wine session:

```bash
WINEPREFIX=~/pfx/nzxt_cam wineserver -k
```

**GPU readings are `n/a`, or the cooler is missing, but only sometimes** — CAM was
started without the launcher. Wine generates its own shortcut for CAM that runs it
directly, and that one starts none of the GPU polling or device fix-ups. Point the
menu entry back at the launcher, and clear away any desktop shortcut that came back
with it:

```bash
~/.local/bin/nzxt-cam-desktop-entries ~/pfx/nzxt_cam
```

The launcher also does this each time it starts, so running `nzxt-cam` once fixes them
too. Only one launcher runs at a time — each supervises CAM and refreshes the GPU
readings, so a second would fight the first — and starting CAM again while it is up
hands the arguments to the copy already running, which brings its window back, out of
the tray if that is where it is.

**Nothing happens when I start CAM, and nothing is logged** — if it is already running
this is expected, and `nzxt-cam` now says so. Otherwise look in the launcher's log,
which is where both a detached launch and the systemd unit write:

```bash
tail -f ~/pfx/nzxt_cam/nzxt-cam.log
systemctl --user status nzxt-cam        # if it was started on login
```

Wine's output must not go to the journal, which is why the unit sends it to that file.
Wine writes a `fixme` line for every stub it hits, hundreds in the first seconds, and
journald's socket buffer fills faster than it drains; the write then blocks and CAM
hangs part-way through starting, with one process, no window and nothing logged. If
you write a unit of your own, give it `StandardOutput=append:` a file, not the
default.

**CAM starts fine but no NZXT device is ever detected** — the cooler is owned by
root. Wine reaches it through `/dev/hidraw*`, and udev leaves those root-only unless a
rule says otherwise, so CAM enumerates nothing: the window looks completely normal
while Cooling and Lighting stay empty. `cam.log` gives it away — `Init device list:`
is followed by the CPU and GPU and no cooler. Check whether you can open it:

```bash
lsusb | grep 1e71                       # find the device
ls -l /dev/hidraw*                      # ours should be crw-rw----+, not crw-------
```

The install offers to write the rule that fixes this; it is skipped when some other
rule already grants access, which is why machines with liquidctl or OpenRGB never see
the problem. To put it in by hand:

```bash
sudo tee /etc/udev/rules.d/60-nzxt-cam.rules >/dev/null <<'RULE'
KERNEL=="hidraw*", ATTRS{idVendor}=="1e71", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1e71", MODE="0660", TAG+="uaccess"
RULE
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw --subsystem-match=usb
```

Then restart CAM, so Wine enumerates the bus again:
`WINEPREFIX=~/pfx/nzxt_cam wineserver -k` and start it back up.

**No text anywhere in the window** — the fonts did not land. Check for them:

```bash
ls ~/pfx/nzxt_cam/drive_c/windows/Fonts/arial.ttf
```

If it is missing, re-run the installer.

**The cooler is not detected after a `wine` package upgrade** — it should not be, any
more. CAM runs against its own copy of Wine in `~/.local/share/nzxt-cam/wine`, which is
where its patched drivers live, and a package upgrade cannot reach it. Check what CAM
is actually using:

```bash
nzxt-cam-wine-tree version
```

If that says "not installed", the tree is missing and the launcher has fallen back to
the system Wine — which has no patched drivers. Rebuilding it re-applies them from the
copy the install kept:

```bash
nzxt-cam-wine-tree create
```

**The window is the wrong size** — set the scale explicitly:

```bash
NZXT_CAM_SCALE=1.5 nzxt-cam
```

Do **not** use Chromium's `--force-device-scale-factor` instead. It sizes the window
correctly but stops cam-core from starting, so no NZXT device is ever detected — the
UI looks completely normal while Cooling and Lighting stay empty and `cam.log` is
empty.

**Inspecting the live UI** — useful when a screenshot will not tell you enough:

```bash
nzxt-cam --remote-debugging-port=9222
curl -s http://127.0.0.1:9222/json    # then drive it over CDP
```

**Logs** live in
`~/pfx/nzxt_cam/drive_c/users/$USER/AppData/Roaming/NZXT CAM/logs/`
(`main.log`, `renderer.log`, `cam.log`, `cam_helper.log`).

**Starting over** — see [Uninstall](../README.md#uninstall). The installer also leaves
`.stock-backup` copies of every DLL it replaces in the prefix's `system32`, but those
go with the prefix.

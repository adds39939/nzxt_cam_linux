# Troubleshooting

**"NZXT CAM can not start while cam_helper.exe is running"** — an orphaned helper is
still alive. Kill the prefix's Wine session:

```bash
WINEPREFIX=~/pfx/nzxt_cam wineserver -k
```

**GPU readings are `n/a`, or the cooler is missing, but only sometimes** — CAM was
started without the launcher. Wine generates its own shortcut for CAM that runs it
directly, and that one starts none of the GPU polling or device fix-ups. Point the
shortcuts back at the launcher:

```bash
~/.local/bin/nzxt-cam-desktop-entries ~/pfx/nzxt_cam
```

The launcher also does this each time it starts, so running `nzxt-cam` once fixes them
too. Note that CAM is not single-instance under Wine: launching it a second way while
it is already running gives two copies fighting over the cooler, which is why the
launcher refuses to start a second one and raises the existing window instead.

**No text anywhere in the window** — the fonts did not land. Check for them:

```bash
ls ~/pfx/nzxt_cam/drive_c/windows/Fonts/arial.ttf
```

If it is missing, re-run the installer.

**The cooler is not detected after a `wine` package upgrade** — the upgrade overwrote
the two patched drivers, which Wine loads from its own install directory rather than
from the prefix. Re-run the installer to put them back, or from a clone:

```bash
sudo ./scripts/install-wine-drivers.sh
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

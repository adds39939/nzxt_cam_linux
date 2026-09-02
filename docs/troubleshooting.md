# Troubleshooting

Everything below assumes the Flatpak. Two shorthands, because they come up constantly:

```bash
FP="flatpak run --command=sh io.github.adds39939.NzxtCamLinux -c"   # a shell in the sandbox
PFX=~/.var/app/io.github.adds39939.NzxtCamLinux/data/wineprefix     # the Wine prefix
```

The prefix is a normal directory on your disk — you can read its logs and settings from
outside the sandbox without any of this. It is only Wine itself that has to be run from
inside, because that is where Wine is.

**"NZXT CAM can not start while cam_helper.exe is running"** — an orphaned helper is
still alive. Every `flatpak run` gets its own PID namespace, so the wineserver you need
to stop is the one inside the running instance:

```bash
flatpak kill io.github.adds39939.NzxtCamLinux
```

If the app is not running at all and you still get this, the prefix has a stale lock:
`$FP 'wineserver -k'` from a fresh instance clears it.

**Nothing happens when I start CAM** — if it is already running this is expected: the
second launch asks the running one to bring its window to the front, out of the tray if
that is where it is, and exits. Otherwise look in the launcher's log:

```bash
tail -f $PFX/nzxt-cam.log
```

Only one launcher runs at a time — each supervises CAM and refreshes the GPU readings,
so a second would fight the first.

**CAM starts fine but no NZXT device is ever detected** — the cooler is owned by root.
Wine reaches it through `/dev/hidraw*`, and udev leaves those root-only unless a rule
says otherwise, so CAM enumerates nothing: the window looks completely normal while
Cooling and Lighting stay empty. `cam.log` gives it away — `Init device list:` is
followed by the CPU and GPU and no cooler. Check whether you can open it:

```bash
lsusb | grep 1e71                       # find the device
ls -l /dev/hidraw*                      # ours should be crw-rw----+, not crw-------
```

A Flatpak cannot install a udev rule, so this one step is on you:

```bash
flatpak run --command=nzxt-cam-setup io.github.adds39939.NzxtCamLinux --udev-help
```

which prints exactly what to run. Machines with liquidctl or OpenRGB already have a
rule for NZXT's vendor id and never see the problem. After installing it, restart the
app so Wine enumerates the bus again.

**No text anywhere in the window** — the fonts did not land. Chromium renders
zero-height text without real fonts and the renderer then dies on a `NOTREACHED`.

```bash
ls $PFX/drive_c/windows/Fonts/arial.ttf
```

If it is missing, the first-run corefonts download failed — most likely no network at
the time. Put it right with:

```bash
flatpak run --command=nzxt-cam-setup io.github.adds39939.NzxtCamLinux --reinstall
```

**The cooler is not detected after a system update** — it cannot be caused by one any
more. The Wine that CAM runs against is inside the Flatpak, and no package manager
touches it. If updating the Flatpak itself is what changed things, install the previous
release's bundle over the top; the prefix is kept, so CAM's settings survive:

```bash
flatpak install --user nzxt-cam-linux.flatpak     # from the older release
```

**The window is the wrong size** — the launcher sets Wine's DPI from the `Xft.dpi` X
resource, which is what KDE and GNOME publish to their X clients. See what it found,
and what it did with it:

```bash
flatpak run --command=nzxt-cam-xdpi io.github.adds39939.NzxtCamLinux   # the DPI, or nothing
grep 'setting Wine' $PFX/nzxt-cam.log                                  # what it applied
```

If it prints nothing, your desktop sets no `Xft.dpi` and the launcher falls back to the
settings portal — which reports only an integer scale, so a fractional one comes out as
100%. Set it explicitly:

```bash
flatpak override --user --env=NZXT_CAM_SCALE=1.5 io.github.adds39939.NzxtCamLinux
```

To confirm the renderer actually took it, `1.45` scaling should show as a
`devicePixelRatio` of `1.4479` (139/96) under the remote debugger below.

Do **not** use Chromium's `--force-device-scale-factor` instead. It sizes the window
correctly but stops cam-core from starting, so no NZXT device is ever detected — the UI
looks completely normal while Cooling and Lighting stay empty and `cam.log` is empty.

**GPU readings are `n/a`** — see which source the poller picked; it says so on stderr,
which goes to the launcher's log:

```bash
grep gpu-poll $PFX/nzxt-cam.log
```

`reading ... via sysfs` is AMD, Intel or nouveau. `through NVML` is NVIDIA's
proprietary driver. `no GPU telemetry available` on an NVIDIA machine means the runtime
has no NVIDIA extension — check that one is installed, which Flatpak normally does by
itself:

```bash
flatpak list | grep GL.nvidia
```

Note that NVIDIA reports fan speed as a percentage where CAM's field is RPM, so the fan
stays `n/a` there by design rather than showing a number in the wrong unit.

**KDE forgets that the tray icon should be hidden** — it comes back in the visible tray
after every reboot. Stock Wine gives its tray icon windows no title, and Plasma's
`xembedsniproxy` then has nothing to identify the icon by except the X11 window id,
which is different on every run — so the "keep this hidden" setting is saved against an
id that never comes back. The patched `explorer.exe` (fix 24 in
[wine-fixes.md](wine-fixes.md)) names the window after the application instead, and the
Flatpak always carries it. Check what the tray sees:

```bash
busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
       org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems |
  sed 's/^as [0-9]* //' | tr -d '"' | tr ' ' '\n' | grep . |
  while read -r item; do
    busctl --user get-property "${item%%/*}" "/${item#*/}" \
           org.kde.StatusNotifierItem Id
  done
```

`s "NZXT CAM"` is what you want. Hide the icon once more the first time it appears
under that name. Old numeric leftovers from the native install accumulate in the
`hiddenItems=` line of `~/.config/plasma-org.kde.plasma.desktop-appletsrc`; they are
harmless, and can be deleted from that line by hand. Plasma reads it at login, so log
out and back in afterwards.

**Inspecting the live UI** — useful when a screenshot will not tell you enough:

```bash
flatpak run io.github.adds39939.NzxtCamLinux --remote-debugging-port=9222
curl -s http://127.0.0.1:9222/json    # then drive it over CDP
```

**Logs** live in `$PFX/drive_c/users/*/AppData/Roaming/NZXT CAM/logs/`
(`main.log`, `renderer.log`, `cam.log`, `cam_helper.log`), and the launcher's own in
`$PFX/nzxt-cam.log`.

**Starting over**

```bash
flatpak uninstall --delete-data io.github.adds39939.NzxtCamLinux
```

That takes the prefix and CAM's settings with it. To keep the app and only rebuild the
prefix, delete `$PFX` and start CAM again — the first-run install runs from scratch.

**Coming from the native install** — the old one put its prefix in `~/pfx/nzxt_cam`,
a launcher in `~/.local/bin/nzxt-cam*`, a private Wine tree in
`~/.local/share/nzxt-cam/`, and possibly a systemd user unit. None of it is used any
more, and the Flatpak starts from a fresh prefix, so CAM's settings and profiles do not
carry over. Clean it up with:

```bash
systemctl --user disable --now nzxt-cam.service 2>/dev/null
rm -f ~/.config/systemd/user/nzxt-cam.service ~/.config/autostart/nzxt-cam.desktop
rm -f ~/.local/bin/nzxt-cam ~/.local/bin/nzxt-cam-*
rm -rf ~/.local/share/nzxt-cam ~/pfx/nzxt_cam
```

The udev rule at `/etc/udev/rules.d/60-nzxt-cam.rules` is the one thing worth keeping —
the Flatpak needs exactly the same rule.

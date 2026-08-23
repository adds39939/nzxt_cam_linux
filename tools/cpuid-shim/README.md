# cpuidsdk64 shim

NZXT CAM reads CPU and GPU telemetry through CPUID's `cpuidsdk64.dll`, which
talks to a ring-0 driver (`cpuz162`). That driver cannot work under Wine, so the
SDK fails to initialise with `0x45A` and CAM reports no CPU at all -- the PC
Monitoring page shows `n/a` for every CPU reading and the LCD has nothing to
display beyond liquid temperature.

The shim is installed as `cpuidsdk64.dll`, with the genuine SDK kept alongside as
`cpuidsdk64_real.dll`. It forwards every call to the real SDK -- which still does
plenty from userspace: CPU topology, model numbers, codename, socket -- and
substitutes only what needs the driver, reading it from Linux instead:

| SDK call (hash) | Meaning                  | Source                          |
|-----------------|--------------------------|---------------------------------|
| `a3fd47fa`      | initialise               | forced to succeed               |
| `602cc059`      | CPU package temperature  | `k10temp` / `coretemp` hwmon    |
| `039a0734`      | per-core clock multiplier| `cpufreq/scaling_cur_freq`      |

## Calling convention

Everything the SDK exports goes through one entry point,
`QueryInterface(uint32 name_hash)`, which returns a function pointer; each of
those is a thin forwarder to a C++ virtual method on the instance object. Two
details make a plain C thunk unusable, so the call path lives in `thunks.S`:

* readings are returned in **XMM0**, not RAX -- a C thunk cannot forward those,
  and the logging path would clobber them;
* several entry points take **arguments on the stack** (the sensor getter takes
  ten), which a fixed four-argument thunk silently drops, passing wild pointers
  to a function that writes through them.

Set `NZXT_CAM_SDK_LOG=1` to trace every call to `C:\sdkproxy.log`.

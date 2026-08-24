#!/usr/bin/env bash
# Write GPU readings to a file for the CPUID shim to pick up, once every INTERVAL.
#
#   scripts/gpu-poll.sh <output-file> [interval-seconds]
#
# Fields, in order:  temperature C, load %, clock MHz, fan, power W, fan unit
# A field is "-" when the driver does not expose it. The fan unit is "rpm" or "pct":
# CAM's field is RPM, so the shim only reports a fan speed when it is really RPM.
#
# The kernel's hwmon interface covers AMD and Intel, and nouveau, without any extra
# package. NVIDIA's proprietary driver is the exception -- it registers no hwmon node
# and exposes nothing useful in sysfs -- so that one alone falls back to nvidia-smi.
set -uo pipefail

OUT="${1:?usage: gpu-poll.sh <output-file> [interval]}"
INTERVAL="${2:-2}"

read_first() {                      # read_first <file>... -> first that exists
    local f
    for f in "$@"; do
        [ -r "$f" ] && { cat "$f" 2>/dev/null; return 0; }
    done
    return 1
}

# The DRM device directory of the first card that exposes any telemetry at all.
find_gpu() {
    local card dev
    for card in /sys/class/drm/card[0-9]*; do
        dev="$card/device"
        [ -e "$dev/vendor" ] || continue
        if [ -d "$dev/hwmon" ] || [ -r "$dev/gpu_busy_percent" ]; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 1
}

GPU_DEV="$(find_gpu || true)"
GPU_HWMON=""
[ -n "$GPU_DEV" ] && GPU_HWMON="$(echo "$GPU_DEV"/hwmon/hwmon[0-9]* 2>/dev/null | awk '{print $1}')"
[ -d "${GPU_HWMON:-/nonexistent}" ] || GPU_HWMON=""

prev_energy=""
prev_time=""

sample_sysfs() {
    local temp load clock fan power unit="pct" raw now energy

    # Temperature: amdgpu starts at temp1, xe's package sensor is temp2.
    raw="$(read_first "$GPU_HWMON/temp1_input" "$GPU_HWMON/temp2_input" 2>/dev/null || true)"
    [ -n "$raw" ] && temp="$(awk -v v="$raw" 'BEGIN{printf "%.0f", v/1000}')" || temp="-"

    # Load: amdgpu only. Intel needs the perf PMU, which is not sysfs.
    raw="$(read_first "$GPU_DEV/gpu_busy_percent" 2>/dev/null || true)"
    [ -n "$raw" ] && load="$raw" || load="-"

    # Clock: amdgpu reports hertz in hwmon, Intel megahertz in the device tree.
    raw="$(read_first "$GPU_HWMON/freq1_input" 2>/dev/null || true)"
    if [ -n "$raw" ]; then
        clock="$(awk -v v="$raw" 'BEGIN{printf "%.0f", v/1000000}')"
    else
        raw="$(read_first "$GPU_DEV/gt_cur_freq_mhz" \
                          "$GPU_DEV"/tile0/gt0/freq0/cur_freq 2>/dev/null || true)"
        [ -n "$raw" ] && clock="$raw" || clock="-"
    fi

    # Fan: real RPM on both amdgpu and xe.
    raw="$(read_first "$GPU_HWMON/fan1_input" 2>/dev/null || true)"
    if [ -n "$raw" ]; then fan="$raw"; unit="rpm"; else fan="-"; fi

    # Power: a direct reading where there is one, otherwise differentiate the
    # energy counter, which is all Intel offers.
    raw="$(read_first "$GPU_HWMON/power1_average" "$GPU_HWMON/power1_input" 2>/dev/null || true)"
    if [ -n "$raw" ]; then
        power="$(awk -v v="$raw" 'BEGIN{printf "%.2f", v/1000000}')"
    elif energy="$(read_first "$GPU_HWMON/energy1_input" 2>/dev/null)"; then
        now="$(date +%s.%N)"
        if [ -n "$prev_energy" ]; then
            power="$(awk -v e1="$prev_energy" -v e2="$energy" -v t1="$prev_time" -v t2="$now" \
                     'BEGIN{d=t2-t1; if (d>0 && e2>=e1) printf "%.2f", (e2-e1)/1000000/d; else printf "-"}')"
        else
            power="-"
        fi
        prev_energy="$energy"; prev_time="$now"
    else
        power="-"
    fi

    printf '%s, %s, %s, %s, %s, %s\n' "$temp" "$load" "$clock" "$fan" "$power" "$unit"
}

sample_nvidia_smi() {
    local line
    line="$(nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.gr,fan.speed,power.draw \
                       --format=csv,noheader,nounits 2>/dev/null | head -1)"
    [ -n "$line" ] || return 1
    # nvidia-smi reports fan as a percentage, which is not what CAM's field wants.
    printf '%s, pct\n' "$line"
}

# Decide once which source to use, rather than probing every two seconds.
SOURCE=""
if [ -n "$GPU_HWMON" ] || [ -r "${GPU_DEV:-/nonexistent}/gpu_busy_percent" ]; then
    SOURCE="sysfs"
elif command -v nvidia-smi >/dev/null 2>&1; then
    SOURCE="nvidia-smi"
fi

case "${SOURCE:-none}" in
    sysfs)      echo "gpu-poll: reading $GPU_DEV via sysfs" >&2 ;;
    nvidia-smi) echo "gpu-poll: no GPU hwmon, using nvidia-smi" >&2 ;;
    *)          echo "gpu-poll: no GPU telemetry available" >&2; exit 0 ;;
esac

while :; do
    if [ "$SOURCE" = "sysfs" ]; then sample_sysfs; else sample_nvidia_smi; fi > "$OUT.tmp" 2>/dev/null
    [ -s "$OUT.tmp" ] && mv -f "$OUT.tmp" "$OUT"
    sleep "$INTERVAL"
done

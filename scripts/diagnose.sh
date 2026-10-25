#!/usr/bin/env bash
set -euo pipefail

echo "=== PS2 Capture Hardware & Signal Diagnostics ==="
echo ""

echo "[1/4] USB Bus Enumeration (MacroSilicon MS2109 / 534d:2109)"
if lsusb | grep -iE "534d:|macrosilicon"; then
    echo "  Status: ONLINE"
else
    echo "  Status: NOT DETECTED on USB bus"
    echo "  Checking recent kernel logs for USB enumeration errors..."
    grep -iE "534d|macrosilicon|error -71|unable to enumerate" /var/log/kern.log 2>/dev/null | tail -n 10 || true
    exit 1
fi
echo ""

echo "[2/4] Video4Linux2 Nodes"
for sysdev in /sys/class/video4linux/video*; do
    [[ -e "$sysdev" ]] || continue
    dev="/dev/$(basename "$sysdev")"
    name="$(cat "$sysdev/name" 2>/dev/null || echo "unknown")"
    idx="$(cat "$sysdev/index" 2>/dev/null || echo "?")"
    echo "  $dev (index $idx): $name"
done
echo ""

echo "[3/4] ALSA & PipeWire Audio Capture Interfaces"
arecord -l 2>/dev/null | grep -E "^card|MS2109|USB" || true
AUDIO_NODE="$(pw-dump 2>/dev/null | grep -oE '"node\.name":\s*"alsa_input\.usb-[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"/\1/' || true)"
echo "  PipeWire Node: ${AUDIO_NODE:-none}"
echo ""

if [[ -n "$AUDIO_NODE" ]]; then
    echo "[4/4] 1-Second Audio Noise-Floor & Ground-Loop Hum DFT Analysis"
    TMP_RAW="$(mktemp --suffix=.raw)"
    trap 'rm -f "$TMP_RAW"' EXIT
    ffmpeg -y -hide_banner -loglevel error -f pulse -i "$AUDIO_NODE" -t 1 -f s16le -ac 2 -ar 48000 "$TMP_RAW"
    python3 - "$TMP_RAW" <<'PY'
import sys, struct, math

data = open(sys.argv[1], "rb").read()
samples = struct.unpack(f"<{len(data)//2}h", data)
left, right = samples[0::2], samples[1::2]

for label, ch in [("Left ", left), ("Right", right)]:
    mean = sum(ch) / len(ch)
    rms = math.sqrt(sum((x - mean) ** 2 for x in ch) / len(ch))
    peak = max(abs(x) for x in ch)
    print(f"  {label} Channel -> DC Offset: {mean:6.1f} | AC RMS: {rms:6.1f} | Peak: {peak:5d} ({20*math.log10(max(peak,1)/32768):5.1f} dBFS)")

N = min(9600, len(left))
print("  Ground-Loop Harmonic Profile (Left Channel):")
for freq in [50, 60, 100, 120, 150, 180, 200, 300]:
    re = sum(left[n] * math.cos(2 * math.pi * freq * n / 48000) for n in range(0, N, 2))
    im = sum(left[n] * math.sin(2 * math.pi * freq * n / 48000) for n in range(0, N, 2))
    mag = math.hypot(re, im) / (N / 2)
    bar = "#" * int(min(mag / 2, 40))
    print(f"    {freq:3d} Hz: {mag:6.1f}  {bar}")
PY
fi

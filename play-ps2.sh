#!/usr/bin/env bash
set -euo pipefail

# Low-latency PS2 Video + Audio Launcher for MacroSilicon (534d:2109) USB Capture Card
# Author: Mayank Padhi

ASPECT_43=1
RAW_MODE=0
DEINTERLACE=1
NO_AUDIO=0
VOL_GAIN="1.0"
POS_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [RESOLUTION] [FPS] [FORMAT]

Low-latency V4L2 video and PipeWire DSP audio launcher for PlayStation 2
hardware connected via a MacroSilicon MS2109 (534d:2109) USB capture device.

Options:
  --4:3, --43         Enforce 4:3 display aspect ratio (default)
  --16:9, --wide      Use 16:9 widescreen aspect ratio (for games with native 16:9 enabled)
  --no-deinterlace    Disable bwdif deinterlacing (use for native 480p progressive scan titles)
  --volume <float>    Audio output gain multiplier (default: 1.0)
  --no-audio          Disable background audio loopback
  --raw               Bypass all video and audio DSP filters
  -h, --help          Show this help message and exit

Positional Arguments:
  RESOLUTION          Capture frame size (default: 1280x720)
  FPS                 Capture frame rate (default: 60)
  FORMAT              V4L2 pixel format: mjpeg or yuyv422 (default: mjpeg)

Examples:
  $(basename "$0")                          # Enhanced 4:3 + bwdif deinterlace + Anti-Hum Audio
  $(basename "$0") --16:9                   # 16:9 widescreen mode
  $(basename "$0") 720x480 60 yuyv422       # Raw uncompressed YUYV at native 480p
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --4:3|--43) ASPECT_43=1; shift ;;
        --16:9|--wide) ASPECT_43=0; shift ;;
        --no-deinterlace) DEINTERLACE=0; shift ;;
        --no-audio) NO_AUDIO=1; shift ;;
        --volume) VOL_GAIN="${2:-1.0}"; shift 2 ;;
        --raw) RAW_MODE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) POS_ARGS+=("$1"); shift ;;
    esac
done

RES="${POS_ARGS[0]:-1280x720}"
FPS="${POS_ARGS[1]:-60}"
FMT="${POS_ARGS[2]:-mjpeg}"

echo "=== PS2 Capture Card Launcher ==="

# 1. Verify USB device presence
if ! lsusb | grep -qiE '534d:|macrosilicon'; then
    echo "[!] MacroSilicon USB Capture Card (534d:2109) is not detected on the USB bus."
    echo "    Run './scripts/diagnose.sh' to inspect kernel USB enumeration logs,"
    echo "    or reseat the capture card firmly and re-run."
    exit 1
fi

# 2. Locate primary V4L2 video capture node (excluding built-in laptop webcams)
VIDEO_DEV=""
for sysdev in /sys/class/video4linux/video*; do
    [[ -e "$sysdev" ]] || continue
    name="$(cat "$sysdev/name" 2>/dev/null || true)"
    index="$(cat "$sysdev/index" 2>/dev/null || echo 0)"
    if [[ "$name" != *"Integrated_Webcam"* ]] && [[ "$index" == "0" ]]; then
        VIDEO_DEV="/dev/$(basename "$sysdev")"
        break
    fi
done

if [[ -z "$VIDEO_DEV" ]]; then
    echo "[!] Capture card detected on USB, but no /dev/videoX capture node is ready."
    exit 1
fi

echo "[+] Video Device : $VIDEO_DEV ($(cat "/sys/class/video4linux/$(basename "$VIDEO_DEV")/name"))"

# 3. Terminate any stale audio loopback processes from previous sessions
pkill -f "pw-loopback.*MACROSILICON|pw-loopback.*MS2109|pw-loopback.*usb-|ffmpeg.*ps2-audio-loopback" 2>/dev/null || true

LOOPBACK_PID=""
cleanup() {
    if [[ -n "$LOOPBACK_PID" ]] && kill -0 "$LOOPBACK_PID" 2>/dev/null; then
        echo "[*] Stopping audio DSP loopback..."
        kill "$LOOPBACK_PID" 2>/dev/null || true
    fi
    pkill -f "ffmpeg.*ps2-audio-loopback" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ "$NO_AUDIO" -eq 0 ]]; then
    AUDIO_NODE=""
    if command -v pw-dump >/dev/null 2>&1; then
        AUDIO_NODE="$(pw-dump 2>/dev/null | grep -oE '"node\.name":\s*"alsa_input\.usb-[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"/\1/' || true)"
    fi

    if [[ -z "$AUDIO_NODE" ]] && command -v pactl >/dev/null 2>&1; then
        AUDIO_NODE="$(pactl list sources short 2>/dev/null | awk '/usb-|534d|MACROSILICON|MS2109/ && !/\.monitor/ {print $2; exit}' || true)"
    fi

    # Anti-hum audio filter: removes 50Hz/60Hz ground-loop + harmonics + adaptive FFT spectral denoiser + noise gate
    AF_CHAIN="highpass=f=150:poles=2,bandreject=f=50:t=q:w=5,bandreject=f=60:t=q:w=5,bandreject=f=100:t=q:w=5,bandreject=f=120:t=q:w=5,bandreject=f=150:t=q:w=5,bandreject=f=180:t=q:w=5,afftdn=nr=24:nf=-40:tn=1,agate=threshold=0.015:ratio=4:range=0.005:attack=5:release=200,volume=${VOL_GAIN}"

    if [[ -n "$AUDIO_NODE" ]]; then
        echo "[+] Audio Source : $AUDIO_NODE"
        if [[ "$RAW_MODE" -eq 1 ]]; then
            echo "[+] Audio Mode   : Raw PipeWire loopback (20ms)"
            pw-loopback --capture="$AUDIO_NODE" --latency="20ms" >/dev/null 2>&1 &
            LOOPBACK_PID=$!
        else
            echo "[+] Audio Mode   : Anti-Hum DSP (50/60Hz harmonic notch + FFT spectral denoiser)"
            ffmpeg -hide_banner -loglevel error \
                -fflags nobuffer -flags low_delay \
                -f pulse -fragment_size 1024 -i "$AUDIO_NODE" \
                -af "$AF_CHAIN" \
                -f pulse -buffer_duration 20 -name "ps2-audio-loopback" default >/dev/null 2>&1 &
            LOOPBACK_PID=$!
        fi
    else
        echo "[!] Warning: USB Audio interface not found. Proceeding with video only."
    fi
fi

# 4. Construct zero-latency spatial video filter chain
VF_CHAIN="format=yuv420p"
if [[ "$RAW_MODE" -eq 0 ]]; then
    if [[ "$DEINTERLACE" -eq 1 ]]; then
        VF_CHAIN="${VF_CHAIN},bwdif=mode=0:parity=-1:deint=0"
    fi
    VF_CHAIN="${VF_CHAIN},hqdn3d=1.5:2.5:0.0:0.0,colorlevels=rimin=0.015:gimin=0.015:bimin=0.015:rimax=0.98:gimax=0.98:bimax=0.98,eq=gamma=1.12:contrast=1.04:saturation=1.14,cas=0.35"
fi
if [[ "$ASPECT_43" -eq 1 ]]; then
    VF_CHAIN="${VF_CHAIN},setdar=4/3"
fi

echo "[+] Video Stream : ${RES} @ ${FPS}fps (${FMT})"
echo "[+] Controls     : 'f' = toggle fullscreen | 'q' or ESC = quit"

ffplay \
    -hide_banner -loglevel error \
    -f v4l2 \
    -input_format "$FMT" \
    -video_size "$RES" \
    -framerate "$FPS" \
    -vf "$VF_CHAIN" \
    -fflags nobuffer \
    -flags low_delay \
    -framedrop \
    -probesize 32 \
    -analyzeduration 0 \
    -sync ext \
    -window_title "PS2 (${VIDEO_DEV} - ${RES}@${FPS} ${FMT})" \
    "$VIDEO_DEV"

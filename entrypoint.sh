#!/usr/bin/env bash
# Camera -> RTMP forwarder
#
# Erforderliche ENV:
#   RTSP_URL    Quell-URL. Schema bestimmt den Demuxer:
#                 rtsp://...                -> RTSP (TCP)
#                 http(s)://...mjpg|mjpeg   -> HTTP MJPEG
#                 http(s)://...             -> HTTP (auto, mjpeg oder generic)
#                 rtmp(s)://...             -> RTMP
#   RTMP_URL    Ziel rtmp://host:1935/live/<key>
#
# Optional:
#   MODE           "copy" (Default) oder "transcode"
#   INPUT_TYPE     "auto" (Default), "rtsp", "http-mjpeg", "rtmp"
#   INPUT_FPS      Framerate fuer MJPEG (Default 15)
#   RW_TIMEOUT     HTTP read/write timeout in us (Default 5000000 = 5s).
#                  ffmpeg killt sich wenn so lang keine Bytes kommen
#                  -> Restart-Loop holt einen frischen Stream
#   VIDEO_CODEC    Default: libx264 (nur bei MODE=transcode)
#   AUDIO_CODEC    Default: aac     (nur bei MODE=transcode)
#   VIDEO_BITRATE  Default: 2000k
#   AUDIO_BITRATE  Default: 128k
#   PRESET         Default: veryfast
#   GOP            Default: 50
#   LOGLEVEL       Default: warning
#   EXTRA_INPUT / EXTRA_OUTPUT

set -euo pipefail

: "${RTSP_URL:?RTSP_URL ist erforderlich}"
: "${RTMP_URL:?RTMP_URL ist erforderlich}"

MODE="${MODE:-copy}"
INPUT_TYPE="${INPUT_TYPE:-auto}"
INPUT_FPS="${INPUT_FPS:-15}"
LOGLEVEL="${LOGLEVEL:-warning}"
PRESET="${PRESET:-veryfast}"
GOP="${GOP:-50}"
VIDEO_CODEC="${VIDEO_CODEC:-libx264}"
AUDIO_CODEC="${AUDIO_CODEC:-aac}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
EXTRA_INPUT="${EXTRA_INPUT:-}"
EXTRA_OUTPUT="${EXTRA_OUTPUT:-}"

# URL-Schema autodetect
if [[ "$INPUT_TYPE" == "auto" ]]; then
  case "$RTSP_URL" in
    rtsp://*)             INPUT_TYPE="rtsp" ;;
    rtmp://*|rtmps://*)   INPUT_TYPE="rtmp" ;;
    http://*|https://*)
      # MJPEG-Hinweise im URL-Pfad
      if echo "$RTSP_URL" | grep -qiE '(videostream\.cgi|mjpg|mjpeg|/video$|\.cgi)'; then
        INPUT_TYPE="http-mjpeg"
      else
        INPUT_TYPE="http-mjpeg"   # Foscam-style ist Default fuer http
      fi
      ;;
    *) echo "[forwarder] unbekanntes URL-Schema: $RTSP_URL" >&2; exit 2 ;;
  esac
fi

SAFE_URL="$(echo "$RTSP_URL" | sed -E 's#(://)[^@/]+@#\1***@#; s#(pwd|password)=[^&]*#\1=***#g')"
echo "[forwarder] Type=$INPUT_TYPE Mode=$MODE Source=$SAFE_URL Target=$RTMP_URL"

# Input-Optionen je nach Quelle
case "$INPUT_TYPE" in
  rtsp)
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -rtsp_transport tcp
      -timeout 10000000
      -fflags +genpts+discardcorrupt
      -use_wallclock_as_timestamps 1
    )
    ;;
  rtmp)
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -fflags +genpts+discardcorrupt
    )
    ;;
  http-mjpeg)
    # MJPEG ueber HTTP: kein Audio, Framerate erzwingen, robust gegen Aussetzer
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -f mjpeg
      -r "$INPUT_FPS"
      -reconnect 1
      -reconnect_streamed 1
      -reconnect_at_eof 1
      -reconnect_on_network_error 1
      -reconnect_on_http_error "4xx,5xx"
      -reconnect_delay_max 5
      -rw_timeout "${RW_TIMEOUT:-5000000}"
      -fflags +genpts+discardcorrupt+nobuffer
      -flags low_delay
      -use_wallclock_as_timestamps 1
    )
    # MJPEG kann nicht copy nach FLV - immer transcoden
    if [[ "$MODE" == "copy" ]]; then
      echo "[forwarder] HTTP/MJPEG erfordert MODE=transcode, schalte um"
      MODE="transcode"
    fi
    ;;
  *)
    echo "[forwarder] Unbekannter INPUT_TYPE='$INPUT_TYPE'" >&2; exit 2 ;;
esac

# Output-Optionen je Mode
if [[ "$MODE" == "copy" ]]; then
  OUTPUT_OPTS=(
    -c copy
    -bsf:a aac_adtstoasc
    -f flv
  )
elif [[ "$MODE" == "transcode" ]]; then
  OUTPUT_OPTS=(
    -c:v "$VIDEO_CODEC"
    -preset "$PRESET"
    -tune zerolatency
    -b:v "$VIDEO_BITRATE"
    -maxrate "$VIDEO_BITRATE"
    -bufsize "$VIDEO_BITRATE"
    -g "$GOP"
    -pix_fmt yuv420p
    -f flv
  )
  # Audio nur wenn die Quelle welches liefert
  if [[ "$INPUT_TYPE" == "http-mjpeg" ]]; then
    OUTPUT_OPTS+=( -an )
  else
    OUTPUT_OPTS+=( -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ar 44100 )
  fi
else
  echo "[forwarder] Unbekannter MODE='$MODE'" >&2; exit 2
fi

# Auto-Restart-Loop
backoff=2
while true; do
  start=$(date +%s)
  set +e
  # shellcheck disable=SC2086
  ffmpeg "${INPUT_OPTS[@]}" $EXTRA_INPUT \
         -i "$RTSP_URL" \
         "${OUTPUT_OPTS[@]}" $EXTRA_OUTPUT \
         "$RTMP_URL"
  rc=$?
  set -e
  end=$(date +%s)
  runtime=$((end - start))
  echo "[forwarder] ffmpeg beendet rc=$rc nach ${runtime}s, Restart in ${backoff}s..."
  if (( runtime > 30 )); then backoff=2
  else backoff=$(( backoff * 2 )); (( backoff > 30 )) && backoff=30; fi
  sleep "$backoff"
done

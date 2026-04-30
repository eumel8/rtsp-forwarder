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
#                  copy = -c:v copy, Audio per AUDIO_MODE (Default: smart)
#   AUDIO_MODE     "smart" (Default), "copy", "aac", "drop"
#                  smart probt die Quelle und macht copy bei AAC, sonst aac.
#                  RTMP/FLV unterstuetzt nur AAC/MP3/Speex - PCM/G.711 muss
#                  zwingend transkodiert werden.
#   INPUT_TYPE     "auto" (Default), "rtsp", "http-mjpeg", "rtmp"
#   INPUT_FPS      Framerate fuer MJPEG (Default 15)
#   RW_TIMEOUT     HTTP read/write timeout in us (Default 5000000 = 5s)
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
AUDIO_MODE="${AUDIO_MODE:-smart}"
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
      if echo "$RTSP_URL" | grep -qiE '(videostream\.cgi|mjpg|mjpeg|/video$|\.cgi)'; then
        INPUT_TYPE="http-mjpeg"
      else
        INPUT_TYPE="http-mjpeg"
      fi
      ;;
    *) echo "[forwarder] unbekanntes URL-Schema: $RTSP_URL" >&2; exit 2 ;;
  esac
fi

SAFE_URL="$(echo "$RTSP_URL" | sed -E 's#(://)[^@/]+@#\1***@#; s#(pwd|password)=[^&]*#\1=***#g')"
echo "[forwarder] Type=$INPUT_TYPE Mode=$MODE AudioMode=$AUDIO_MODE Source=$SAFE_URL Target=$RTMP_URL"

# Probe Audio-Codec der Quelle (nur RTSP/RTMP, MJPEG hat per Definition kein Audio).
# Setzt SOURCE_AUDIO_CODEC auf "none" wenn keiner gefunden, sonst Codec-Name (z.B. aac, pcm_alaw, opus).
probe_audio_codec() {
  local codec=""
  local probe_opts=( -hide_banner -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 )
  case "$INPUT_TYPE" in
    rtsp)
      codec=$(timeout 10 ffprobe -rtsp_transport tcp "${probe_opts[@]}" "$RTSP_URL" 2>/dev/null | head -n1 || true)
      ;;
    rtmp)
      codec=$(timeout 10 ffprobe "${probe_opts[@]}" "$RTSP_URL" 2>/dev/null | head -n1 || true)
      ;;
    *)
      codec=""
      ;;
  esac
  if [[ -z "$codec" ]]; then
    echo "none"
  else
    echo "$codec"
  fi
}

resolve_audio_mode() {
  local requested="$1"
  if [[ "$INPUT_TYPE" == "http-mjpeg" ]]; then
    echo "drop"
    return
  fi
  if [[ "$requested" != "smart" ]]; then
    echo "$requested"
    return
  fi
  local detected
  detected=$(probe_audio_codec)
  case "$detected" in
    none)
      echo "[forwarder] audio probe: keine Audio-Spur erkannt -> drop" >&2
      echo "drop" ;;
    aac)
      echo "[forwarder] audio probe: aac -> copy" >&2
      echo "copy" ;;
    *)
      echo "[forwarder] audio probe: $detected nicht RTMP-kompatibel -> aac transcode" >&2
      echo "aac" ;;
  esac
}

EFFECTIVE_AUDIO_MODE=$(resolve_audio_mode "$AUDIO_MODE")

# Input-Optionen je nach Quelle
case "$INPUT_TYPE" in
  rtsp)
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -rtsp_transport tcp
      -timeout 10000000
      -fflags +genpts+discardcorrupt
      -use_wallclock_as_timestamps 1
      -avoid_negative_ts make_zero
    )
    ;;
  rtmp)
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -fflags +genpts+discardcorrupt
    )
    ;;
  http-mjpeg)
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
    if [[ "$MODE" == "copy" ]]; then
      echo "[forwarder] HTTP/MJPEG erfordert MODE=transcode, schalte um"
      MODE="transcode"
    fi
    ;;
  *)
    echo "[forwarder] Unbekannter INPUT_TYPE='$INPUT_TYPE'" >&2; exit 2 ;;
esac

audio_output_args() {
  case "$EFFECTIVE_AUDIO_MODE" in
    drop)
      echo "-an" ;;
    copy)
      echo "-c:a copy -bsf:a aac_adtstoasc" ;;
    aac)
      echo "-c:a aac -b:a $AUDIO_BITRATE -ar 44100 -ac 1" ;;
    *)
      echo "[forwarder] unbekannter AUDIO_MODE='$EFFECTIVE_AUDIO_MODE'" >&2
      echo "-an" ;;
  esac
}

# Output-Optionen je Mode
build_output_opts() {
  if [[ "$MODE" == "copy" ]]; then
    OUTPUT_OPTS=(
      -c:v copy
      -flvflags no_duration_filesize
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
      -flvflags no_duration_filesize
      -f flv
    )
  else
    echo "[forwarder] Unbekannter MODE='$MODE'" >&2; exit 2
  fi
  # shellcheck disable=SC2207
  OUTPUT_OPTS+=( $(audio_output_args) )
}
build_output_opts

echo "[forwarder] Output: mode=$MODE audio=$EFFECTIVE_AUDIO_MODE"

# Auto-Restart-Loop
backoff=2
short_fails=0
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

  # Auto-Fallback: copy-Mode kann nicht mit fehlenden PTS umgehen. Wenn die
  # Quelle wiederholt schnell stirbt, schalten wir auf transcode um. Das
  # generiert garantiert PTS und ueberlebt auch komische RTSP-Profile.
  if (( runtime <= 30 )) && [[ "$MODE" == "copy" ]]; then
    short_fails=$((short_fails + 1))
    if (( short_fails >= 3 )); then
      echo "[forwarder] copy-Mode 3x kurz hintereinander gescheitert -> Fallback auf MODE=transcode"
      MODE=transcode
      build_output_opts
      echo "[forwarder] Output (fallback): mode=$MODE audio=$EFFECTIVE_AUDIO_MODE"
      short_fails=0
    fi
  else
    short_fails=0
  fi

  if (( runtime > 30 )); then backoff=2
  else backoff=$(( backoff * 2 )); (( backoff > 30 )) && backoff=30; fi
  sleep "$backoff"
done

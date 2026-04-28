#!/usr/bin/env bash
# RTMP/RTSP -> MP4 segment recorder
#
# Erforderliche ENV:
#   SOURCE_URL    z.B. rtmp://nginx-rtmp.media.svc:1935/live/cam01
#                 oder rtsp://user:pass@10.0.0.20:554/Streaming/Channels/101
#   CAMERA_NAME   z.B. cam01 (Subverzeichnis & Dateiname-Prefix)
#
# Optionale ENV:
#   REC_DIR        Default: /recordings
#   SEGMENT_TIME   Default: 3600  (Sekunden pro File)
#   RETENTION_DAYS Default: 30    (älter wird gelöscht)
#   CLEAN_INTERVAL Default: 21600 (6h, in Sekunden)
#   LOGLEVEL       Default: warning
#   EXTRA_INPUT / EXTRA_OUTPUT  zusätzliche ffmpeg Optionen

set -euo pipefail

: "${SOURCE_URL:?SOURCE_URL ist erforderlich}"
: "${CAMERA_NAME:?CAMERA_NAME ist erforderlich}"

REC_DIR="${REC_DIR:-/recordings}"
SEGMENT_TIME="${SEGMENT_TIME:-3600}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
CLEAN_INTERVAL="${CLEAN_INTERVAL:-21600}"
LOGLEVEL="${LOGLEVEL:-warning}"
EXTRA_INPUT="${EXTRA_INPUT:-}"
EXTRA_OUTPUT="${EXTRA_OUTPUT:-}"

CAM_DIR="$REC_DIR/$CAMERA_NAME"
mkdir -p "$CAM_DIR"

SAFE_SRC="$(echo "$SOURCE_URL" | sed -E 's#(://)[^@/]+@#\1***@#')"
echo "[recorder] Camera=$CAMERA_NAME  Source=$SAFE_SRC  Dir=$CAM_DIR  Segment=${SEGMENT_TIME}s  Retention=${RETENTION_DAYS}d"

# Hintergrund-Cleanup: löscht Dateien älter als RETENTION_DAYS
cleanup_loop() {
  while true; do
    sleep "$CLEAN_INTERVAL"
    deleted=$(find "$CAM_DIR" -type f -name '*.mp4' -mtime "+$RETENTION_DAYS" -print -delete 2>/dev/null | wc -l)
    if [[ "$deleted" -gt 0 ]]; then
      echo "[recorder] cleanup: $deleted alte Dateien gelöscht (>${RETENTION_DAYS}d)"
    fi
  done
}
cleanup_loop &
CLEAN_PID=$!
trap 'kill $CLEAN_PID 2>/dev/null || true' EXIT

# Quelle: URL-Schema bestimmt Input-Optionen
case "$SOURCE_URL" in
  rtsp://*)
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -rtsp_transport tcp
      -timeout 10000000
      -fflags +genpts+discardcorrupt
    )
    ;;
  rtmp://*|rtmps://*)
    INPUT_OPTS=(
      -hide_banner -loglevel "$LOGLEVEL"
      -fflags +genpts+discardcorrupt
    )
    ;;
  *)
    echo "[recorder] Unbekanntes URL-Schema: $SOURCE_URL" >&2
    exit 2
    ;;
esac

# Output: rolling MP4 segments mit Datums-Pr\u00e4fix im Dateinamen (flat layout)
# /recordings/cam01/cam01_2026-04-28_22-00-00.mp4
OUTPUT_PATTERN="$CAM_DIR/${CAMERA_NAME}_%Y-%m-%d_%H-%M-%S.mp4"

OUTPUT_OPTS=(
  -c copy
  -bsf:a aac_adtstoasc
  -f segment
  -segment_time "$SEGMENT_TIME"
  -segment_atclocktime 1
  -reset_timestamps 1
  -strftime 1
  -segment_format mp4
  -segment_format_options "movflags=+faststart"
)

backoff=2
while true; do
  start=$(date +%s)
  set +e
  # shellcheck disable=SC2086
  ffmpeg "${INPUT_OPTS[@]}" $EXTRA_INPUT \
         -i "$SOURCE_URL" \
         "${OUTPUT_OPTS[@]}" $EXTRA_OUTPUT \
         "$OUTPUT_PATTERN"
  rc=$?
  set -e
  end=$(date +%s)
  runtime=$((end - start))
  echo "[recorder] ffmpeg beendet rc=$rc nach ${runtime}s, Restart in ${backoff}s..."
  if (( runtime > 30 )); then backoff=2
  else backoff=$(( backoff * 2 )); (( backoff > 30 )) && backoff=30; fi
  sleep "$backoff"
done

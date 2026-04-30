# Roadmap

The core loop is complete: **Capture → Transport → Persist → Browse**.
Everything below is optional — ideas for rainy weekends, in roughly increasing
order of effort.

## Motion detection

Run a sidecar (or replace the recorder for selected cameras) that uses
ffmpeg's `select='gt(scene,0.1)'` filter to only persist segments which
actually contain motion. Index events as JSON next to the MP4.

- Storage savings: ~90 % for static scenes
- New chart values: `motionThreshold`, `preRollSec`, `postRollSec`
- Web UI: filter "events only", timeline view

## Live preview in recordings-web

Add an HLS `<video>` tag fed from the existing nginx-rtmp `/hls` endpoint,
so the same UI shows both **live** and **recorded** streams.

- Requires nginx-rtmp `hls on;` + `application live { hls on; }` block
- Web UI: per-camera "Live" tab next to the recording grid

## Notifications

On new motion event, send a push notification (Telegram bot, ntfy.sh,
Matrix, …) including the generated thumbnail.

- Webhook receiver in `recordings-web` or as separate small service
- Chart values for endpoint, token, per-camera enable

## Object detection

YOLO / frigate-style classification on motion events. CPU-only viable for a
few cameras, GPU node for more.

- Optional Coral TPU support
- Tag MP4s with detected classes (person, car, …) and surface in UI
- This will eat a whole weekend

## Off-cluster backup

CronJob with `restic` or `rclone` pushing recordings to S3 / B2 / Hetzner
Object Storage every night.

- Encrypted at rest off-site
- Retention policy independent from local PVC retention
- Restore documented in `charts/rtsp-recorder/README.md`

## Smaller polish

- Cosign signatures on the three GHCR images
- Liveness probe via `ffprobe` on the active RTMP stream (forwarder)
- Renovate config to keep Helm/Node/ffmpeg base images current
- Recorder layout fix: drop the redundant `<cam>/<cam>/` subdirectory
  (currently worked around in `recordings-web`)
- Sealed-secrets / SOPS for camera credentials and basic-auth htpasswd

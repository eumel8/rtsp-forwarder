# RTSP Streaming Stack

[![build](https://github.com/eumel8/rtsp-forwarder/actions/workflows/build.yaml/badge.svg)](https://github.com/eumel8/rtsp-forwarder/actions/workflows/build.yaml)

Two complementary components for IP-camera streaming on Kubernetes:

| Component        | Image                                    | Chart                                                    |
|------------------|------------------------------------------|----------------------------------------------------------|
| `rtsp-forwarder` | `ghcr.io/eumel8/rtsp-forwarder`          | `oci://ghcr.io/eumel8/charts/rtsp-forwarder`             |
| `rtsp-recorder`  | `ghcr.io/eumel8/rtsp-recorder`           | `oci://ghcr.io/eumel8/charts/rtsp-recorder`              |
| `recordings-web` | `ghcr.io/eumel8/recordings-web`          | `oci://ghcr.io/eumel8/charts/recordings-web`             |

```
[ IP camera ] --RTSP--> [ rtsp-forwarder ] --RTMP--> [ nginx-rtmp ] --RTMP--> [ rtsp-recorder ] --MP4 segments--> PVC
                                                            |                                                       |
                                                            +--RTMP/HLS--> live viewers      [ recordings-web ] <---+
```

## rtsp-forwarder

## Features

- RTSP over **TCP** (stable, low packet loss)
- Modes **`copy`** (no transcoding, ~50m CPU) and **`transcode`** (H.264/AAC for H.265 cameras)
- Automatic **reconnect** with exponential backoff
- Read-only root FS, non-root user (UID 10001), dropped capabilities
- Multi-arch image (linux/amd64, linux/arm64)

## Install via Helm (recommended)

```bash
helm install fwd oci://ghcr.io/eumel8/charts/rtsp-forwarder \
  -n media --create-namespace \
  -f my-values.yaml
```

Minimal `my-values.yaml`:

```yaml
cameras:
  - name: cam01
    rtspUrl: "rtsp://user:pass@10.0.0.20:554/Streaming/Channels/101"
    rtmpUrl: "rtmp://nginx-rtmp.media.svc.cluster.local:1935/live/cam01"
    mode: copy
  - name: cam02
    rtspUrl: "rtsp://user:pass@10.0.0.21:554/cam/realmonitor?channel=1&subtype=0"
    rtmpUrl: "rtmp://nginx-rtmp.media.svc.cluster.local:1935/live/cam02"
    mode: transcode
    videoBitrate: "2500k"
```

Tail logs:

```bash
kubectl -n media logs -f deploy/fwd-rtsp-forwarder-cam01
```

## Plain manifests (without Helm)

See `k8s/forwarder.yaml`. Adjust `RTSP_URL` / `RTMP_URL` and `kubectl apply -f k8s/forwarder.yaml`.

## ENV reference (container)

| Variable        | Default     | Description |
|-----------------|-------------|-------------|
| `RTSP_URL`      | *required*  | Full RTSP URL incl. user:pass |
| `RTMP_URL`      | *required*  | Target URL e.g. `rtmp://host:1935/live/cam01` |
| `MODE`          | `copy`      | `copy` or `transcode` |
| `VIDEO_CODEC`   | `libx264`   | transcode only |
| `AUDIO_CODEC`   | `aac`       | transcode only |
| `VIDEO_BITRATE` | `2000k`     | transcode only |
| `AUDIO_BITRATE` | `128k`      | transcode only |
| `PRESET`        | `veryfast`  | x264 preset |
| `GOP`           | `50`        | keyframe interval (frames) |
| `LOGLEVEL`      | `warning`   | ffmpeg log level |
| `EXTRA_INPUT`   | -           | extra ffmpeg input flags |
| `EXTRA_OUTPUT`  | -           | extra ffmpeg output flags |

## When to use `copy` vs. `transcode`?

- **`copy`**: camera delivers H.264 + AAC (or no audio). Almost no CPU load.
- **`transcode`**: camera delivers H.265/HEVC, G.711/PCM audio, or other RTMP-incompatible
  formats. RTMP/FLV officially supports only H.264 + AAC/MP3.

Quick check:

```bash
ffprobe -rtsp_transport tcp "rtsp://user:pass@10.0.0.20:554/..."
```

If `Video: h264` and `Audio: aac` -> `mode: copy`. Otherwise `transcode`.

## Test the RTMP output

```bash
kubectl -n media port-forward svc/nginx-rtmp 1935:1935
ffplay rtmp://localhost:1935/live/cam01
```

## Local build

```bash
docker build -t ghcr.io/eumel8/rtsp-forwarder:dev .
```

## CI / Release

GitHub Actions workflow `.github/workflows/build.yaml`:

- on push to `main`: builds multi-arch image, tags `:latest` + `:sha-<sha>`, pushes Helm chart
  with the version from `Chart.yaml` to `ghcr.io/eumel8/charts/rtsp-forwarder`.
- on tag `v*.*.*`: tags the image with semver tags (`:1.2.3`, `:1.2`).

**Releases later**: bump chart versions in `charts/*/Chart.yaml` to publish a new release.

## rtsp-recorder

Records the RTMP output of nginx-rtmp as **rolling MP4 segments** to a PVC per camera.
`-c copy` only, no transcoding.

```bash
helm install rec oci://ghcr.io/eumel8/charts/rtsp-recorder \
  -n media -f recorder-values.yaml
```

Minimal `recorder-values.yaml`:

```yaml
cameras:
  - name: cam01
    sourceUrl: "rtmp://nginx-rtmp-server.nginx-rtmp-server.svc.cluster.local:1935/live/cam01"
    storage:
      size: "100Gi"
    retentionDays: "30"
```

Files land at `/recordings/<cam>/<cam>_<YYYY-MM-DD>_<HH-MM-SS>.mp4`,
default 1h segments, segment boundaries aligned to wall clock.
A background loop deletes files older than `retentionDays` every 6h.

See `charts/rtsp-recorder/README.md` and `charts/rtsp-recorder/values.yaml` for the full reference.

## recordings-web

Web UI to browse, play and delete the MP4 segments produced by `rtsp-recorder`.
Node.js + Express, native HTML5 player with HTTP Range requests (seekable),
ffmpeg thumbnails, ffprobe metadata. Mounts the recorder PVCs read/write
(or read-only with `allowDelete: false`).

```bash
helm install rec-web oci://ghcr.io/eumel8/charts/recordings-web \
  -n media -f recordings-web-values.yaml
```

Minimal `recordings-web-values.yaml`:

```yaml
title: "CCTV Recordings"
allowDelete: true

cameras:
  - name: cam01
    existingClaim: rec-rtsp-recorder-cam01
  - name: cam02
    existingClaim: rec-rtsp-recorder-cam02
```

Optional ingress with basic-auth — generate the htpasswd entry without
installing apache2-utils, using just `openssl`:

```bash
# user=admin, password=somesecret  (APR1 / MD5, supported by nginx-ingress)
printf "admin:$(openssl passwd -apr1 'somesecret')\n"
```

Drop the resulting line into `basicAuth.htpasswd` in your values file and
enable `ingress`. See `charts/recordings-web/README.md` for the full reference,
ingress annotations and the persistent thumbnail cache option.

# recordings-web

Web UI to browse, play and delete recorded MP4 segments produced by the
[`rtsp-recorder`](../rtsp-recorder/) chart.

## Features

- Per-camera overview with thumbnail grid
- HTML5 player with HTTP Range requests (seekable)
- Per-file metadata via `ffprobe` (codec, resolution, fps, bitrate, duration)
- Download button
- Optional delete (`allowDelete: true`)
- Ingress with optional Basic-Auth via `basicAuth.htpasswd`

## Install

```sh
helm install rec-web oci://ghcr.io/eumel8/charts/recordings-web \
  -n nginx-rtmp-server \
  -f values.yaml
```

### values.yaml example

```yaml
title: "CCTV Recordings"
allowDelete: true

cameras:
  - name: cam01
    existingClaim: rec-rtsp-recorder-cam01
  - name: cam02
    existingClaim: rec-rtsp-recorder-cam02

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: rec-web-recordings-web-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "Recordings"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
  hosts:
    - host: recordings.example.com
      paths:
        - path: /
          pathType: Prefix

basicAuth:
  enabled: true
  # produced by: htpasswd -nb admin 'somesecret'
  htpasswd: "admin:$apr1$..."
```

## Notes

- The web pod must run on the same node as the recorder pods when using
  `local-path` RWO PVCs. Schedule with `nodeSelector` if needed.
- `allowDelete: false` mounts all camera PVCs read-only.
- Thumbnails are cached in `/var/cache/thumbs` (emptyDir by default).
  Set `thumbnailCache.enabled: true` for a persistent cache.

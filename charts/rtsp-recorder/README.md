# rtsp-recorder

Helm chart for recording RTMP/RTSP streams as rolling MP4 segments to a PVC per camera.

## Install

```bash
helm install rec oci://ghcr.io/eumel8/charts/rtsp-recorder \
  --version 0.1.0 \
  -n media \
  -f my-values.yaml
```

## Minimal values

```yaml
cameras:
  - name: cam01
    sourceUrl: "rtmp://nginx-rtmp-server.nginx-rtmp-server.svc.cluster.local:1935/live/cam01"
    storage:
      size: "100Gi"
    retentionDays: "30"
```

## File layout on disk

```
/recordings/
  cam01/
    cam01_2026-04-28_22-00-00.mp4
    cam01_2026-04-28_23-00-00.mp4
    cam01_2026-04-29_00-00-00.mp4
  cam02/
    cam02_2026-04-28_22-00-00.mp4
```

Files older than `retentionDays` are removed every `cleanInterval` seconds (default 6h).

## Notes

- Pulls from RTMP (preferred — already normalized H.264/AAC) but can also consume RTSP directly.
- Uses `-c copy` — no transcoding, near-zero CPU.
- `-segment_atclocktime 1` aligns segment boundaries to the wall clock so files start at full hours.
- One PVC per camera (RWO). For RWX/shared storage adapt `accessMode` and provide a suitable StorageClass.

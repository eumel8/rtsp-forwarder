# rtsp-forwarder

Helm chart that runs one ffmpeg pod per IP camera, forwarding RTSP to an nginx-RTMP server.

## Install from OCI registry

```bash
helm install fwd oci://ghcr.io/eumel8/charts/rtsp-forwarder \
  --version 0.1.0 \
  -n media --create-namespace \
  -f my-values.yaml
```

## Quick start values

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
```

Set `useSecrets: true` to keep RTSP credentials in a Kubernetes Secret instead of plain env values.

See `values.yaml` for the full reference.

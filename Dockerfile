# Schlankes Image mit ffmpeg für RTSP -> RTMP Forwarding
FROM alpine:3.20

RUN apk add --no-cache ffmpeg bash tini ca-certificates \
    && adduser -D -u 10001 ffmpeg

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ffmpeg

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]

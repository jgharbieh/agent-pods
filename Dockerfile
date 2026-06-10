FROM debian:bookworm-slim

# Chromium + virtual display + VNC + noVNC web viewer + CDP bridge
# + xdotool (real X cursor control for humanized UI testing)
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    fonts-liberation \
    fonts-noto-color-emoji \
    xvfb \
    x11-utils \
    x11vnc \
    novnc \
    websockify \
    socat \
    xdotool \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY glide-click /usr/local/bin/glide-click
RUN chmod +x /entrypoint.sh /usr/local/bin/glide-click

# 9222 = CDP (bridged via socat), 7900 = noVNC web viewer
EXPOSE 9222 7900

HEALTHCHECK --interval=5s --timeout=3s --start-period=15s --retries=5 \
  CMD curl -sf http://127.0.0.1:9221/json/version > /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]

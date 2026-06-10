#!/bin/bash
set -e

SCREEN_W="${SCREEN_W:-1600}"
SCREEN_H="${SCREEN_H:-900}"

# Virtual display
Xvfb :99 -screen 0 "${SCREEN_W}x${SCREEN_H}x24" -nolisten tcp &
export DISPLAY=:99

# Wait for X to come up
for _ in $(seq 1 50); do
  if xdpyinfo > /dev/null 2>&1; then break; fi
  sleep 0.1
done

# Headed Chromium with CDP on an internal port.
# Chromium only binds CDP to 127.0.0.1, so socat bridges it to 0.0.0.0:9222 below.
chromium \
  --no-sandbox \
  --disable-dev-shm-usage \
  --remote-debugging-port=9221 \
  --user-data-dir=/data/profile \
  --no-first-run \
  --no-default-browser-check \
  --disable-session-crashed-bubble \
  --window-position=0,0 \
  --window-size="${SCREEN_W},${SCREEN_H}" \
  "about:blank" &

# CDP bridge: container-external 9222 -> chromium-internal 9221
socat TCP-LISTEN:9222,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:9221 &

# VNC server on the virtual display
x11vnc -display :99 -forever -shared -nopw -quiet -noxdamage &

# noVNC web viewer on 7900 (browse to /vnc.html)
websockify --web /usr/share/novnc 7900 localhost:5900 &

# Die if any service dies; docker restart policy / pod.ps1 handles the rest
wait -n

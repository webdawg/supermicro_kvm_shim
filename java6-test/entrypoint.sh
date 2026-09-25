#!/bin/bash
set -uo pipefail

: "${BMC_HOST:?Set BMC_HOST}"
: "${BMC_USER:?Set BMC_USER}"
: "${BMC_PASS:?Set BMC_PASS}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
SCREEN_GEOM="${SCREEN_GEOM:-1280x900x24}"

export DISPLAY=:98

XFONTPATH="/usr/share/fonts/X11/misc,/usr/share/fonts/X11/75dpi,/usr/share/fonts/X11/100dpi,/usr/share/fonts/X11/Type1"
Xvfb "$DISPLAY" -screen 0 "$SCREEN_GEOM" -nolisten tcp -fp "$XFONTPATH" &
sleep 1
fluxbox >/dev/null 2>&1 &

if [ -n "$VNC_PASSWORD" ]; then
  mkdir -p "$HOME/.vnc"
  x11vnc -storepasswd "$VNC_PASSWORD" "$HOME/.vnc/passwd" >/dev/null
  X11VNC_AUTH=(-rfbauth "$HOME/.vnc/passwd")
else
  X11VNC_AUTH=(-nopw)
fi

x11vnc -display "$DISPLAY" -forever -shared "${X11VNC_AUTH[@]}" -rfbport 5901 -quiet &
websockify --web=/usr/share/novnc/ 6081 localhost:5901 &

# Different port than the main kvm-shim container's local jar mirror
# (8765) -- network_mode: host means both containers share the host's
# port namespace.
export LOCAL_CODEBASE="http://127.0.0.1:8766/"
mkdir -p /work/jars
(cd /work/jars && python3 -m http.server 8766 --bind 127.0.0.1 >/dev/null 2>&1) &

echo "[shim/java6] noVNC:  http://<this-host>:6081/vnc.html"
echo "[shim/java6] VNC:    <this-host>:5901"

while true; do
  echo "[shim/java6] Logging into $BMC_HOST and fetching a fresh console session..."
  if python3 /opt/shim/login_and_launch.py; then
    echo "[shim/java6] Launching applet under real Java 6 (same patches as the Java 8 setup)..."
    appletviewer \
      -J-Djava.security.policy=/opt/shim/security/all.policy \
      /work/console.html
    echo "[shim/java6] Console window closed or session ended."
  else
    echo "[shim/java6] Login failed -- check BMC_HOST/BMC_USER/BMC_PASS."
  fi
  sleep 5
  echo "[shim/java6] Reconnecting..."
done

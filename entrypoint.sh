#!/bin/bash
set -uo pipefail

: "${BMC_HOST:?Set BMC_HOST}"
: "${BMC_USER:?Set BMC_USER}"
: "${BMC_PASS:?Set BMC_PASS}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
SCREEN_GEOM="${SCREEN_GEOM:-1280x900x24}"

export DISPLAY=:99

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

x11vnc -display "$DISPLAY" -forever -shared "${X11VNC_AUTH[@]}" -rfbport 5900 -quiet &
websockify --web=/usr/share/novnc/ 6080 localhost:5900 &

mkdir -p /work/jars
(cd /work/jars && python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1) &

echo "[shim] noVNC:  http://<this-host>:6080/vnc.html"
echo "[shim] VNC:    <this-host>:5900"

while true; do
  echo "[shim] Logging into $BMC_HOST and fetching a fresh console session..."
  if python3 /opt/shim/login_and_launch.py; then
    echo "[shim] Launching legacy iKVM applet..."
    # KbdFactory picks a keyboard scancode translator class by JVM
    # default locale (nn.pp.rckbd.KeyTranslator_<locale>). This
    # firmware never shipped one for en_US (only en_GB, de, fr, ja,
    # no, sv, de_CH, fr_CH), so it silently falls back to the generic
    # translator -- which sends real, correctly-ACKed packets (see
    # tcpdump capture during troubleshooting) but with scancode=0,
    # a no-op the BMC correctly ignores. Force en_GB so a real
    # translator loads instead.
    LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8 appletviewer \
      -J-Djava.security.properties=/opt/shim/security/java.security.overrides \
      -J-Djava.security.policy=/opt/shim/security/all.policy \
      -J-Duser.language=en -J-Duser.country=GB \
      /work/console.html
    echo "[shim] Console window closed or session ended."
  else
    echo "[shim] Login failed -- check BMC_HOST/BMC_USER/BMC_PASS."
  fi
  sleep 5
  echo "[shim] Reconnecting..."
done

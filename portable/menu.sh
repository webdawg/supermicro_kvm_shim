#!/bin/bash
# Self-contained start/stop/status menu for the kvm-shim console.
# Everything this needs (rootfs/, proot-x86_64, env.list,
# credentials.env) lives next to this script -- no Docker, no root, no
# package manager, nothing installed on this machine. Runs the exact
# same image contents as the Docker version, just via proot instead of
# a container runtime.
set -uo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS="$BUNDLE_DIR/rootfs"
PROOT="$BUNDLE_DIR/proot-x86_64"
CREDS="$BUNDLE_DIR/credentials.env"
ENVLIST="$BUNDLE_DIR/env.list"

if [ ! -d "$ROOTFS" ] || [ ! -x "$PROOT" ]; then
  echo "This doesn't look like a complete bundle (missing rootfs/ or proot-x86_64 next to this script)." >&2
  exit 1
fi

RUNDIR="$BUNDLE_DIR/run"
if ! mkdir -p "$RUNDIR" 2>/dev/null; then
  RUNDIR="/tmp/kvm-shim-portable-run"
  mkdir -p "$RUNDIR"
fi
PIDFILE="$RUNDIR/kvm-shim.pid"
LOGFILE="$RUNDIR/kvm-shim.log"

detect_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

print_urls() {
  local ip
  ip="$(detect_ip)"
  echo
  echo "  Landing page: http://localhost:6080/"
  [ -n "$ip" ] && echo "                http://$ip:6080/"
  echo "  Connect:      http://localhost:6080/connect.html  (forces a fresh session)"
  echo "  noVNC direct: http://localhost:6080/vnc.html"
  echo "  Raw VNC:      localhost:5900"
  echo
}

wait_for_port() {
  local port="$1" timeout="${2:-60}" waited=0
  while ! ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 1
  done
  return 0
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "-$pid" 2>/dev/null
}

cred_value() {
  # Reads one KEY=value out of credentials.env without sourcing it.
  grep "^$1=" "$CREDS" 2>/dev/null | head -1 | cut -d= -f2-
}

needs_setup() {
  [ "$(cred_value BMC_PASS)" = "changeme" ]
}

do_edit_credentials() {
  local cur_host cur_user cur_vnc in_host in_user in_pass in_vnc
  cur_host="$(cred_value BMC_HOST)"
  cur_user="$(cred_value BMC_USER)"
  cur_vnc="$(cred_value VNC_PASSWORD)"
  echo "Enter the BMC to connect to (blank = keep current value shown in [brackets])."
  read -r -p "BMC host/IP [$cur_host]: " in_host
  read -r -p "BMC username [$cur_user]: " in_user
  read -rs -p "BMC password: " in_pass; echo
  read -r -p "VNC password, optional [$cur_vnc]: " in_vnc
  cat > "$CREDS" <<EOF
BMC_HOST=${in_host:-$cur_host}
BMC_USER=${in_user:-$cur_user}
BMC_PASS=${in_pass:-changeme}
VNC_PASSWORD=${in_vnc:-$cur_vnc}
EOF
  echo "Saved to $CREDS"
}

do_start() {
  if is_running; then
    echo "Already running."
    print_urls
    return
  fi
  if needs_setup; then
    echo "credentials.env still has the example password -- let's set the real ones first."
    do_edit_credentials
  fi
  : > "$LOGFILE"
  (
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$CREDS"
    source "$ENVLIST"
    set +a
    export HOME=/root
    BINDS=(-b /dev -b /proc -b /sys)
    [ -e /etc/resolv.conf ] && BINDS+=(-b /etc/resolv.conf)
    setsid "$PROOT" -0 -r "$ROOTFS" "${BINDS[@]}" -w /work /bin/bash /opt/shim/entrypoint.sh \
      > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
  )
  echo "Starting (logs into the BMC, brings up Xvfb/noVNC -- can take a few seconds)..."
  if wait_for_port 6080 90; then
    echo "Up."
    print_urls
  else
    echo "Not responding on :6080 after 90s. Check the log:"
    echo "  tail -f '$LOGFILE'"
  fi
}

do_stop() {
  if ! is_running; then
    echo "Not running."
    rm -f "$PIDFILE"
    return
  fi
  local pid
  pid="$(cat "$PIDFILE")"
  echo "Stopping (process group $pid)..."
  kill -TERM "-$pid" 2>/dev/null || true
  for _ in $(seq 1 10); do
    kill -0 "-$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "-$pid" 2>/dev/null; then
    kill -KILL "-$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  echo "Stopped."
}

do_status() {
  if is_running; then
    echo "Running."
    print_urls
  else
    echo "Not running."
  fi
}

show_menu() {
  echo "=================================="
  echo " Supermicro KVM Shim -- portable"
  echo "=================================="
  if is_running; then
    echo " Status: RUNNING"
  else
    echo " Status: stopped"
  fi
  echo
  echo " 1) Start"
  echo " 2) Stop"
  echo " 3) Status"
  echo " 4) Edit BMC credentials (host/user/password)"
  echo " 5) Exit"
  echo
}

# Non-interactive one-shot usage: kvm-shim.sh start|stop|status|creds
case "${1:-}" in
  start)  do_start;  exit 0 ;;
  stop)   do_stop;   exit 0 ;;
  status) do_status; exit 0 ;;
  creds)  do_edit_credentials; exit 0 ;;
esac

while true; do
  show_menu
  read -r -p "Choose: " choice
  case "$choice" in
    1) do_start ;;
    2) do_stop ;;
    3) do_status ;;
    4) do_edit_credentials ;;
    5) echo "Exiting menu (service, if running, stays up)."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
  echo
done

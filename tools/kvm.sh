#!/bin/bash
# On-demand start/stop for the KVM shim -- it's not meant to run all
# the time. `kvm.sh` (or `kvm.sh start`) brings it up and prints the
# URL; `kvm.sh stop` fully tears it down (stop + remove container, no
# leftover state).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

URL="http://localhost:6080/"
TIMEOUT=60

cmd_start() {
  echo "[kvm] Starting..."
  docker compose up -d --build kvm-shim

  echo -n "[kvm] Waiting for it to come up"
  local waited=0
  until curl -s -o /dev/null -w '' "$URL" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    echo -n "."
    if [ "$waited" -ge "$TIMEOUT" ]; then
      echo
      echo "[kvm] Still not responding after ${TIMEOUT}s -- check logs:"
      echo "      docker compose logs -f kvm-shim"
      exit 1
    fi
  done
  echo
  echo "[kvm] Ready:  $URL"
}

cmd_stop() {
  echo "[kvm] Stopping and removing..."
  docker compose stop kvm-shim
  docker compose rm -f kvm-shim
  echo "[kvm] Cleaned up. Nothing left running."
}

cmd_status() {
  if docker compose ps kvm-shim --format '{{.State}}' 2>/dev/null | grep -q running; then
    echo "[kvm] Running: $URL"
  else
    echo "[kvm] Not running."
  fi
}

case "${1:-start}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 [start|stop|status]"
    exit 1
    ;;
esac

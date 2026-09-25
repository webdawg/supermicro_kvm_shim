#!/bin/bash
# Unattended full scancode sweep: tries base values 0x00-0x7F with
# correct standard PS/2 polarity (via /work/scancode_override, see
# login_and_launch.py's patch_rfbhandler_keylog), sending a '9'
# keypress at each and diffing before/after screenshots to flag any
# value that visibly changes the remote screen.
#
# Run from the host (not inside the container):
#   tools/scancode_sweep.sh [start_hex] [end_hex]
#
# Results land in $RESULTS_DIR/results.log (one line per value) and
# $RESULTS_DIR/<hex>_before.png / <hex>_after.png for every value,
# so a later session can review without re-running anything.
set -uo pipefail

CONTAINER=supermicro_kvm_shim
WINDOW_NAME="Supermicro Daughter Card Remote Console"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/../sweep_results}"
START="${1:-0}"
END="${2:-127}"

mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/results.log"
echo "=== sweep started $(date -Iseconds), range $START-$END ===" >> "$LOG"

dexec() { sg docker -c "docker exec $CONTAINER bash -c \"$1\""; }

for ((val=START; val<=END; val++)); do
  hex=$(printf '%02x' "$val")

  dexec "echo $hex > /work/scancode_override" >/dev/null 2>&1
  sg docker -c "docker exec $CONTAINER pkill appletviewer" >/dev/null 2>&1
  sleep 11   # login + reconnect
  sleep 3    # let the transient "desktop size" overlay clear

  dexec "DISPLAY=:99 import -window root /tmp/sweep_before.png" >/dev/null 2>&1

  dexec "
    WID=\\\$(DISPLAY=:99 xdotool search --name '$WINDOW_NAME' | head -1)
    DISPLAY=:99 xdotool windowactivate --sync \\\$WID
    DISPLAY=:99 xdotool mousemove 500 400
    DISPLAY=:99 xdotool click 1
    sleep 0.3
    DISPLAY=:99 xdotool key --clearmodifiers 9
    sleep 1
  " >/dev/null 2>&1

  dexec "DISPLAY=:99 import -window root /tmp/sweep_after.png" >/dev/null 2>&1

  diffline=$(dexec "compare -metric AE /tmp/sweep_before.png /tmp/sweep_after.png /tmp/sweep_diff.png 2>&1")

  sg docker -c "docker cp $CONTAINER:/tmp/sweep_before.png $RESULTS_DIR/${hex}_before.png" >/dev/null 2>&1
  sg docker -c "docker cp $CONTAINER:/tmp/sweep_after.png $RESULTS_DIR/${hex}_after.png" >/dev/null 2>&1

  echo "$(date -Iseconds) value=0x$hex diff=$diffline" | tee -a "$LOG"
done

dexec "rm -f /work/scancode_override" >/dev/null 2>&1
sg docker -c "docker exec $CONTAINER pkill appletviewer" >/dev/null 2>&1

echo "=== sweep finished $(date -Iseconds) ===" >> "$LOG"
echo "SWEEP COMPLETE. Review $LOG for diff counts -- any value with a"
echo "much higher diff than its neighbors (a blinking-cursor baseline"
echo "noise level will be present throughout) is worth checking by eye:"
echo "  $RESULTS_DIR/<hex>_after.png"

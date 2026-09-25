#!/bin/bash
# Grab-bag of ipmitool commands for poking at old/flaky Supermicro IPMI
# hardware -- BMC resets, power control, sensor/event log dumps, SOL,
# etc. Reads BMC_HOST/BMC_USER/BMC_PASS from the environment (already
# set in this container via .env / docker-compose.yml).
#
# Usage (from the host):
#   docker compose exec kvm-shim bmc-tools.sh <command> [args...]
set -euo pipefail

: "${BMC_HOST:?Set BMC_HOST}"
: "${BMC_USER:?Set BMC_USER}"
: "${BMC_PASS:?Set BMC_PASS}"

IPMI=(ipmitool -I lanplus -H "$BMC_HOST" -U "$BMC_USER" -P "$BMC_PASS")

usage() {
  cat <<EOF
Usage: bmc-tools.sh <command> [args...]

Status / info:
  status              Chassis power status
  info                BMC firmware/device info (mc info)
  lan                 BMC's own network config (lan print)
  users               IPMI user list
  fru                 Hardware inventory (FRU data)
  sensors             Live sensor readings (sdr elist)

Power control (affects the HOST SERVER -- be careful):
  power on            Power on
  power off           Hard power off
  power cycle         Power cycle (off then on)
  power reset         Hard reset (like the reset button)
  power soft          ACPI soft shutdown (like a power-button press)

Event log:
  sel list            Show the System Event Log
  sel clear           Clear the System Event Log

BMC-only actions (does NOT affect the host OS/server):
  reset-bmc           Cold-reset the BMC/IPMI chip (mc reset cold)
  reset-bmc-warm      Warm-reset the BMC/IPMI chip (mc reset warm)

Console:
  sol                 Activate Serial-over-LAN (text console, Ctrl+] to exit)
  sol-deactivate      Force-deactivate a stuck SOL session

Raw:
  raw ...             Pass args straight through to ipmitool
EOF
}

confirm() {
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

cmd="${1:-}"
shift || true

case "$cmd" in
  status)
    "${IPMI[@]}" chassis status
    ;;
  info)
    "${IPMI[@]}" mc info
    ;;
  lan)
    "${IPMI[@]}" lan print
    ;;
  users)
    "${IPMI[@]}" user list 1
    ;;
  fru)
    "${IPMI[@]}" fru print
    ;;
  sensors)
    "${IPMI[@]}" sdr elist
    ;;
  power)
    sub="${1:-}"
    case "$sub" in
      on|off|cycle|reset|soft)
        if [[ "$sub" != "on" ]]; then
          confirm "This will $sub the HOST SERVER. Continue?" || exit 1
        fi
        "${IPMI[@]}" chassis power "$sub"
        ;;
      *)
        echo "Usage: bmc-tools.sh power {on|off|cycle|reset|soft}" >&2
        exit 1
        ;;
    esac
    ;;
  sel)
    sub="${1:-}"
    case "$sub" in
      list) "${IPMI[@]}" sel list ;;
      clear)
        confirm "Clear the System Event Log?" && "${IPMI[@]}" sel clear
        ;;
      *)
        echo "Usage: bmc-tools.sh sel {list|clear}" >&2
        exit 1
        ;;
    esac
    ;;
  reset-bmc)
    confirm "Cold-reset the BMC ($BMC_HOST)? This does NOT reboot the host server, but the web UI/KVM/SOL will drop for a minute or two." \
      && "${IPMI[@]}" mc reset cold
    ;;
  reset-bmc-warm)
    confirm "Warm-reset the BMC ($BMC_HOST)?" \
      && "${IPMI[@]}" mc reset warm
    ;;
  sol)
    echo "[bmc-tools] Starting SOL session. Use '~.' or Ctrl+] then 'q' to exit, depending on terminal." >&2
    "${IPMI[@]}" sol activate
    ;;
  sol-deactivate)
    "${IPMI[@]}" sol deactivate
    ;;
  raw)
    "${IPMI[@]}" "$@"
    ;;
  ""|help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac

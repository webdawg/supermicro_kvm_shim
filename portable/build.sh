#!/bin/bash
# Builds a fully self-contained, "nothing installed" bundle: exports the
# existing kvm-shim Docker image's filesystem and pairs it with a static
# proot binary, so the result runs on any x86_64 Linux box with no
# Docker, no root, and no package manager -- just extract and run
# kvm-shim.sh.
#
# Run THIS script on a machine that already has Docker (this one does).
# The output tarball (portable/dist/kvm-shim-portable-x86_64.tar.gz) is
# what you copy to the actual target box.
set -euo pipefail

RELEASE=0
if [ "${1:-}" = "--release" ]; then
  RELEASE=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$DIST_DIR/kvm-shim-portable"
IMAGE_TAG="kvm-shim-portable-build"
PROOT_URL="https://proot.gitlab.io/proot/bin/proot"
PROOT_BIN="$VENDOR_DIR/proot-x86_64"

# docker wrapper: use a plain docker call, falling back to `sg docker`
# only if that fails on a permission error (covers setups where the
# invoking shell hasn't picked up docker-group membership yet).
dockercmd() {
  local errfile
  errfile="$(mktemp)"
  if docker "$@" 2>"$errfile"; then
    rm -f "$errfile"
    return 0
  fi
  if grep -qi "permission denied" "$errfile"; then
    rm -f "$errfile"
    local cmdstr
    printf -v cmdstr '%q ' "$@"
    sg docker -c "docker $cmdstr"
    return $?
  fi
  cat "$errfile" >&2
  rm -f "$errfile"
  return 1
}

mkdir -p "$VENDOR_DIR" "$DIST_DIR"

if [ ! -x "$PROOT_BIN" ]; then
  echo "[build] Fetching static proot binary..."
  curl -fsSL -o "$PROOT_BIN" "$PROOT_URL"
  chmod +x "$PROOT_BIN"
fi
if ! file "$PROOT_BIN" | grep -q "statically linked"; then
  echo "[build] ERROR: $PROOT_BIN doesn't look like a static binary -- aborting." >&2
  exit 1
fi
echo "[build] proot OK: $("$PROOT_BIN" --version 2>&1 | head -1)"

echo "[build] Building kvm-shim image ($IMAGE_TAG)..."
dockercmd build -t "$IMAGE_TAG" "$REPO_DIR"

echo "[build] Capturing image environment..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ENV_JSON="$(dockercmd inspect "$IMAGE_TAG" --format '{{json .Config.Env}}')"
python3 - "$ENV_JSON" > "$STAGE_DIR/env.list" <<'PYEOF'
import json, shlex, sys
envs = json.loads(sys.argv[1])
for kv in envs:
    key, _, val = kv.partition("=")
    print(f"{key}={shlex.quote(val)}")
PYEOF
echo "[build]   $(wc -l < "$STAGE_DIR/env.list") env vars captured"

echo "[build] Exporting container filesystem (this is the big one, be patient)..."
mkdir -p "$STAGE_DIR/rootfs"
CID="$(dockercmd create "$IMAGE_TAG")"
dockercmd export "$CID" | tar -C "$STAGE_DIR/rootfs" -xf -
dockercmd rm "$CID" >/dev/null

if [ "$RELEASE" -eq 1 ]; then
  echo "[build] Writing credentials.env (placeholder values -- release build)..."
  cat > "$STAGE_DIR/credentials.env" <<'EOF'
# Example credentials -- edit the three BMC_* lines below (or just run
# `./kvm-shim.sh` and pick "Edit BMC credentials", which prompts for
# these interactively and also fires automatically the first time you
# hit Start while BMC_PASS is still "changeme"). Re-read fresh on every
# Start, no rebuild needed.
BMC_HOST=10.0.99.215
BMC_USER=root
BMC_PASS=changeme
VNC_PASSWORD=
EOF
else
  echo "[build] Writing credentials.env (hardcoded from this repo's .env)..."
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
  cat > "$STAGE_DIR/credentials.env" <<EOF
# Hardcoded BMC credentials for this portable bundle. Edit freely --
# re-read fresh on every "Start", no rebuild needed.
BMC_HOST=${BMC_HOST}
BMC_USER=${BMC_USER}
BMC_PASS=${BMC_PASS}
VNC_PASSWORD=${VNC_PASSWORD:-}
EOF
fi

cp "$PROOT_BIN" "$STAGE_DIR/proot-x86_64"
chmod +x "$STAGE_DIR/proot-x86_64"
cp "$SCRIPT_DIR/menu.sh" "$STAGE_DIR/kvm-shim.sh"
chmod +x "$STAGE_DIR/kvm-shim.sh"

echo "[build] Packaging tarball..."
if [ "$RELEASE" -eq 1 ]; then
  OUT="$DIST_DIR/kvm-shim-portable-x86_64-release.tar.gz"
else
  OUT="$DIST_DIR/kvm-shim-portable-x86_64.tar.gz"
fi
( cd "$DIST_DIR" && tar czf "$(basename "$OUT")" kvm-shim-portable )
SIZE="$(du -h "$OUT" | cut -f1)"

echo
echo "[build] Done: $OUT ($SIZE)"
echo "[build] Copy that single file to the target box, then:"
echo "          tar xzf $(basename "$OUT")"
echo "          cd kvm-shim-portable"
echo "          ./kvm-shim.sh"

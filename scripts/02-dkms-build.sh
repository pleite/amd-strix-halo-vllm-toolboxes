#!/usr/bin/env bash
#
# 02-dkms-build.sh — build + install the thunderbolt_ibverbs kernel module from
# the DKMS source staged in the image, against the *running host kernel*.
#
# This must run inside the toolbox with the host's /lib/modules visible
# (toolbox/distrobox bind-mount the host filesystem by default) and with
# permission to write the built module back. It is idempotent: if the module is
# already built for the running kernel it does nothing.
#
# NOTE: Loading the module (`modprobe thunderbolt_ibverbs ...`) and the
# peer_auth_acl PSK configuration are HOST operations — do them on the host, not
# in the container. See docs/tb-vllm-toolbox-recommendations.md.
#
set -euo pipefail

TBNET_PATH="${TBNET_PATH:-/opt/tbnet}"
KVER="${KVER:-$(uname -r)}"

log()  { printf '\033[1;36m[dkms]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[dkms][error]\033[0m %s\n' "$*" >&2; }

if ! command -v dkms >/dev/null 2>&1; then
  err "dkms is not installed in this image"; exit 1
fi

VERSION="$(cat "${TBNET_PATH}/DKMS_VERSION" 2>/dev/null || echo 0.3.1)"
MODULE="thunderbolt-ibverbs/${VERSION}"
DKMS_SRC="/usr/src/thunderbolt-ibverbs-${VERSION}"

if [ ! -d "$DKMS_SRC" ]; then
  err "DKMS source not staged at ${DKMS_SRC}"; exit 1
fi

# Kernel build tree is required (host kernel-devel mounted via /lib/modules).
if [ ! -d "/lib/modules/${KVER}/build" ]; then
  err "Missing /lib/modules/${KVER}/build — start the toolbox with host"
  err "/lib/modules visible and install kernel-devel-${KVER} on the host."
  exit 2
fi

if dkms status "$MODULE" 2>/dev/null | grep -q "${KVER}.*installed"; then
  log "thunderbolt_ibverbs already built+installed for ${KVER}"
  exit 0
fi

log "Registering ${MODULE} with DKMS"
dkms status "$MODULE" 2>/dev/null | grep -q "$VERSION" || dkms add "$DKMS_SRC"

log "Building ${MODULE} for kernel ${KVER}"
dkms build "$MODULE" -k "$KVER"

log "Installing ${MODULE} for kernel ${KVER}"
dkms install "$MODULE" -k "$KVER"

log "Done. Load it on the HOST with:"
log "  sudo modprobe thunderbolt_ibverbs profile=linux_perf \\"
log "    bind_services=1 allocate_rings=1 start_rings=1 \\"
log "    negotiate_native=1 enable_tunnels=1 register_verbs=1"

#!/usr/bin/env bash
#
# build_tbnet_userspace.sh — build the thunderbolt-ibverbs userspace pieces that
# belong *inside* the tb-vllm-toolbox container.
#
# What runs here is the host-independent userspace only:
#   1. proto/ freestanding smoke-test binaries (no kernel, no rdma-core)
#   2. the usb4_rdma libibverbs provider, so the container's stock libibverbs.so
#      enumerates `usb4_rdma*` devices that the *host* kernel module exposes
#   3. staging the DKMS source tree under /usr/src so the kernel module can be
#      built at runtime against the host's /lib/modules (see 02-dkms-build.sh)
#
# The kernel module itself is NOT built here — it must be compiled against the
# running host kernel, which is only available when the container is started
# with the host /lib/modules bind-mounted. See docs/tb-vllm-toolbox-plan.md and
# docs/tb-vllm-toolbox-recommendations.md.
#
# Environment:
#   TBV_REPO   git URL of the thunderbolt-ibverbs source (default: pleite fork)
#   TBV_REF    git ref / commit to check out (default: pinned commit)
#   TBNET_PATH install prefix for userspace artifacts (default: /opt/tbnet)
#   TBV_BUILD_PROVIDER  1 to build the usb4_rdma provider RPM (default: 1)
#   RDMA_CORE_TAG       rdma-core tag the provider is built against (default v62.0)
#
set -euo pipefail

TBV_REPO="${TBV_REPO:-https://github.com/pleite/thunderbolt-ibverbs.git}"
TBV_REF="${TBV_REF:-95c98aa4bc88a6ef3b992aa955e372573e09dce8}"
TBNET_PATH="${TBNET_PATH:-/opt/tbnet}"
TBV_BUILD_PROVIDER="${TBV_BUILD_PROVIDER:-1}"
export RDMA_CORE_TAG="${RDMA_CORE_TAG:-v62.0}"

SRC_DIR="${TBNET_PATH}/src"
BIN_DIR="${TBNET_PATH}/bin"
INC_DIR="${TBNET_PATH}/include"

log() { printf '\033[1;36m[tbnet]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[tbnet][warn]\033[0m %s\n' "$*" >&2; }

mkdir -p "$BIN_DIR" "$INC_DIR"

# ---------------------------------------------------------------------------
# 1. Fetch source
# ---------------------------------------------------------------------------
log "Cloning $TBV_REPO @ $TBV_REF"
rm -rf "$SRC_DIR"
git clone --filter=blob:none "$TBV_REPO" "$SRC_DIR"
git -C "$SRC_DIR" checkout --quiet "$TBV_REF"
cp -a "$SRC_DIR/proto" "$INC_DIR/proto"

# ---------------------------------------------------------------------------
# 2. Build the freestanding proto smoke tests
#    These compile without kernel headers or rdma-core and give a quick
#    in-container sanity check of the wire protocol / reliability / identity /
#    config code paths.
# ---------------------------------------------------------------------------
CC="${CC:-gcc}"
CFLAGS="-Wall -Wextra -std=c11 -O2 -I${SRC_DIR}"

# smoke binary -> list of extra proto/*.c translation units it needs
declare -A SMOKE_SOURCES=(
  [proto-smoke]=""
  [reliability-smoke]="proto/reliability.c"
  [identity-smoke]="proto/identity.c"
  [config-smoke]="proto/config.c proto/identity.c"
)

build_smoke() {
  local name="$1" extra="$2" src="${SRC_DIR}/tools/ci/${1}.c"
  [ -f "$src" ] || { warn "missing $src — skipping"; return 0; }
  local objs=()
  local f
  for f in $extra; do objs+=("${SRC_DIR}/${f}"); done
  if "$CC" $CFLAGS -o "${BIN_DIR}/${name}" "$src" "${objs[@]}" 2>"${BIN_DIR}/${name}.log"; then
    log "built ${name}"
    rm -f "${BIN_DIR}/${name}.log"
  else
    warn "could not build ${name} (see ${BIN_DIR}/${name}.log) — continuing"
  fi
}

for name in "${!SMOKE_SOURCES[@]}"; do
  build_smoke "$name" "${SMOKE_SOURCES[$name]}"
done

# ---------------------------------------------------------------------------
# 3. Build + install the usb4_rdma libibverbs provider
#    Reuses the upstream packaging script so the provider .so is built against
#    a known rdma-core (PABI) and produces a native RPM we install into the
#    image. If the PABI of the produced provider does not match the container's
#    libibverbs the install still succeeds, but `ibv_devices` may not enumerate
#    the device — this is one of the things to validate on real hardware.
# ---------------------------------------------------------------------------
if [ "$TBV_BUILD_PROVIDER" = "1" ]; then
  log "Building usb4_rdma provider (rdma-core ${RDMA_CORE_TAG})"
  if (cd "$SRC_DIR" && OUT_DIR="$SRC_DIR/dist" bash tools/ci/distro-package-rdma.sh fedora); then
    rpm=$(ls -1 "$SRC_DIR"/dist/usb4-rdma-provider-*.rpm 2>/dev/null | head -n1 || true)
    if [ -n "$rpm" ]; then
      cp "$rpm" "$BIN_DIR/"
      dnf install -y "$rpm" || warn "provider RPM install failed — install on host instead"
      log "installed provider: $(basename "$rpm")"
    else
      warn "provider RPM not produced — falling back to host install"
    fi
  else
    warn "provider build failed — the container will rely on a host-installed provider"
  fi

  # Always try to copy the .driver file for libibverbs auto-loading
  # (the RPM may not install it, or it may be missing from the dist/ output)
  if [ -f "$SRC_DIR/dist/usb4_rdma.driver" ]; then
    cp "$SRC_DIR/dist/usb4_rdma.driver" "$BIN_DIR/"
    log "staged usb4_rdma.driver"
  elif [ -f "$SRC_DIR/providers/usb4_rdma/usb4_rdma.driver" ]; then
    cp "$SRC_DIR/providers/usb4_rdma/usb4_rdma.driver" "$BIN_DIR/"
    log "staged usb4_rdma.driver (from providers/)"
  else
    warn "usb4_rdma.driver not found — provider may not auto-load"
  fi
else
  log "Skipping provider build (TBV_BUILD_PROVIDER=$TBV_BUILD_PROVIDER)"
fi

# ---------------------------------------------------------------------------
# 4. Stage the DKMS source tree for a runtime build against the host kernel
# ---------------------------------------------------------------------------
PKG_VERSION="$(awk -F'"' '/^PACKAGE_VERSION=/ {print $2; exit}' "$SRC_DIR/dkms.conf")"
PKG_VERSION="${PKG_VERSION:-0.3.1}"
DKMS_SRC="/usr/src/thunderbolt-ibverbs-${PKG_VERSION}"
log "Staging DKMS source at ${DKMS_SRC} (version ${PKG_VERSION})"
rm -rf "$DKMS_SRC"
cp -a "$SRC_DIR" "$DKMS_SRC"
# Record the version so 02-dkms-build.sh can find the staged tree at runtime.
printf '%s\n' "$PKG_VERSION" > "${TBNET_PATH}/DKMS_VERSION"

log "Userspace build complete. Artifacts under ${TBNET_PATH}."

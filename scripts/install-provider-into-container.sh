#!/usr/bin/env bash
#
# install-provider-into-container.sh — drop the usb4_rdma provider .so
# and .driver files into a running container when the RPM install fails
# due to PABI mismatch (Fedora 43's libibverbs v58.0 vs provider built
# against rdma-core v62.0).
#
# The provider artifacts are staged inside the tb-vllm-toolbox image at
# $TBNET_PATH/bin/ during the build. This script copies them into the
# container's libibverbs directories and runs ldconfig.
#
# Usage:
#   install-provider-into-container.sh <container-name-or-id>
#
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <container-name-or-id>"
    echo ""
    echo "This installs the usb4_rdma libibverbs provider into a toolbox"
    echo "or podman container when the RPM install fails due to PABI mismatch."
    exit 1
fi

CONTAINER="$1"
TBNET_PATH="${TBNET_PATH:-/opt/tbnet}"

echo "Installing usb4_rdma provider into container: $CONTAINER"

# The provider .so and .driver are staged inside the container image at $TBNET_PATH/bin/
# during the build. We copy them from there into the proper libibverbs locations.

# Discover the staged provider .so by glob — the filename embeds the rdma-core
# PABI version (e.g. libusb4_rdma-rdmav59.so) which can change across builds.
so_name=$(podman exec "$CONTAINER" bash -c \
  "ls ${TBNET_PATH}/bin/libusb4_rdma-*.so 2>/dev/null | head -1 | xargs -r basename")
if [ -z "$so_name" ]; then
    echo "ERROR: No libusb4_rdma-*.so found in container at ${TBNET_PATH}/bin/"
    echo "The file should have been staged during image build."
    exit 1
fi

# Copy provider .so
podman exec --user root "$CONTAINER" mkdir -p /usr/lib64/libibverbs /etc/libibverbs.d
podman exec --user root "$CONTAINER" cp "${TBNET_PATH}/bin/${so_name}" /usr/lib64/libibverbs/ || {
    echo "ERROR: Failed to copy ${so_name} into /usr/lib64/libibverbs/"
    exit 1
}

# Copy .driver file (libibverbs reads this to locate the provider at runtime)
podman exec --user root "$CONTAINER" cp "${TBNET_PATH}/bin/usb4_rdma.driver" /etc/libibverbs.d/ 2>/dev/null || {
    echo "WARNING: usb4_rdma.driver not found in container — creating from staged .so name"
    # The .driver file format is: driver <library-base-name>
    # Strip the -rdmavXX.so suffix to get the base name (e.g. libusb4_rdma).
    lib_base="${so_name%-rdmav*.so}"
    podman exec --user root "$CONTAINER" bash -c \
      "printf 'driver %s\n' '${lib_base}' > /etc/libibverbs.d/usb4_rdma.driver"
}

# Run ldconfig inside the container
podman exec --user root "$CONTAINER" ldconfig 2>/dev/null || true

echo "Done. Verify with:"
echo "  podman exec $CONTAINER ibv_devices"

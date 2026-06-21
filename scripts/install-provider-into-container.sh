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

# Copy provider .so
podman exec "$CONTAINER" mkdir -p /usr/lib64/libibverbs /etc/libibverbs.d 2>/dev/null || true
podman exec "$CONTAINER" cp "$TBNET_PATH/bin/libusb4_rdma-rdmav59.so" /usr/lib64/libibverbs/ 2>/dev/null || {
    echo "ERROR: Cannot find libusb4_rdma-rdmav59.so in container at $TBNET_PATH/bin/"
    echo "The file should have been staged during image build."
    exit 1
}

# Copy .driver file
podman exec "$CONTAINER" cp "$TBNET_PATH/bin/usb4_rdma.driver" /etc/libibverbs.d/ 2>/dev/null || {
    echo "WARNING: usb4_rdma.driver not found in container"
    echo "Creating placeholder .driver file..."
    podman exec "$CONTAINER" bash -c "echo usb4_rdma > /etc/libibverbs.d/usb4_rdma.driver"
}

# Run ldconfig inside the container
podman exec "$CONTAINER" ldconfig 2>/dev/null || true

echo "Done. Verify with:"
echo "  podman exec $CONTAINER ibv_devices"

# 01-tbnet-env.sh — thunderbolt-ibverbs (tbnet) environment for the toolbox.
# Sourced from /etc/profile.d at shell start.

# Install prefix for the userspace artifacts built by build_tbnet_userspace.sh.
export TBNET_PATH="${TBNET_PATH:-/opt/tbnet}"

# Put the proto smoke-test binaries and helpers on PATH.
case ":$PATH:" in
  *":$TBNET_PATH/bin:"*) : ;;
  *) [ -d "$TBNET_PATH/bin" ] && PATH="$TBNET_PATH/bin:$PATH" ;;
esac
export PATH

# RDMA / NCCL / RCCL defaults for the usb4_rdma transport. These mirror the
# thunderbolt-ibverbs vLLM-toolbox integration guide. NCCL_IB_HCA is left unset
# on purpose: it must match the device name reported by `ibv_devices`
# (e.g. usb4_rdma0). Export it before launching a cluster:
#
#   export NCCL_IB_HCA=usb4_rdma0
#   export RCCL_IB_HCA=usb4_rdma0
#
export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
export NCCL_NET_GDR_LEVEL="${NCCL_NET_GDR_LEVEL:-0}"
export NCCL_IB_TIMEOUT="${NCCL_IB_TIMEOUT:-23}"
export NCCL_IB_RETRY_CNT="${NCCL_IB_RETRY_CNT:-7}"

# RCCL mirror vars (AMD RCCL 2.18+ uses RCCL_ prefix):
export RCCL_IB_DISABLE="${RCCL_IB_DISABLE:-0}"
export RCCL_NET_GDR_LEVEL="${RCCL_NET_GDR_LEVEL:-0}"
export RCCL_IB_TIMEOUT="${RCCL_IB_TIMEOUT:-23}"
export RCCL_IB_RETRY_CNT="${RCCL_IB_RETRY_CNT:-7}"
# GPU-direct (dma-buf path, requires CONFIG_TBV_GPU_DIRECT kernel module).
# To enable, override the exports above in your session or cluster launch script:
#   export RCCL_NET_GDR_LEVEL=3
#   export NCCL_NET_GDR_LEVEL=3

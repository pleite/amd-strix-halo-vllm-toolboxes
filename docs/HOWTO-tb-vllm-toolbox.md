# HOWTO: TB-vLLM Toolbox Setup

This guide covers the complete process for setting up and using the `tb-vllm-toolbox` container on a Strix Halo (AMD ROCm) system with thunderbolt-ibverbs support.

---

## Prerequisites

### Host System Requirements

| Requirement | Details |
|---|---|
| **OS** | Fedora 43 (or similar RPM-based) |
| **Kernel** | 7.0.12-101.fc43.x86_64+ (with `configfs` support) |
| **Container Runtime** | Podman (Docker works if aliased) |
| **GPU** | Strix Halo (Radeon 8050S/8060S Graphics) |
| **Thunderbolt** | Optional — required for ibverbs transport |

### 1. Install ROCm Dependencies

```bash
# Install base ROCm packages
sudo dnf install -y rocm-hip-runtime rocm-opencl-runtime rocm-smi

# Install ibverbs utilities (for device discovery)
sudo dnf install -y libibverbs-utils

# Install RDMA development packages (for tbnet builds)
sudo dnf install -y libibverbs-devel rdma-core-devel libnl3-devel
```

### 2. Kernel Module Setup

The `thunderbolt_ibverbs` kernel module must be loaded for Thunderbolt-based RDMA:

```bash
# Load the module
sudo modprobe thunderbolt_ibverbs

# Verify it's loaded
lsmod | grep thunderbolt
```

Expected output:
```
thunderbolt_ibverbs    389120  0
ib_uverbs             225280  1 thunderbolt_ibverbs
ib_core               598016  2 thunderbolt_ibverbs,ib_uverbs
thunderbolt           618496  2 thunderbolt_ibverbs,typec
```

### 3. Install USB4 RDMA Provider

The provider RPM is built as part of the tbnet build process:

```bash
# From container (copy first):
podman run --rm ghcr.io/pleite/tb-vllm-toolbox:dev \
  cat /opt/tbnet/bin/usb4-rdma-provider-*.rpm > /tmp/usb4-rdma-provider.rpm

# Install on host:
sudo dnf install -y /tmp/usb4-rdma-provider.rpm
```

### 4. Verify Device Nodes

Ensure the following device nodes exist and are accessible:

```bash
ls -la /dev/dri/card* /dev/dri/renderD* /dev/kfd
```

Expected output:
```
crw-rw----. 1 root video  226,   1 Jun 21 00:17 /dev/dri/card1
crw-rw-rw-. 1 root render 226, 128 Jun 18 00:00 /dev/dri/renderD128
crw-rw-rw-. 1 root render 235,   0 Jun 18 00:00 /dev/kfd
```

---

## Container Creation

### Basic Command

```bash
podman run --rm -it \
  --device /dev/dri/card1 \
  --device /dev/dri/renderD128 \
  --device /dev/kfd \
  --network host \
  --cap-add SYS_PTRACE \
  --security-opt seccomp=unconfined \
  --env HIP_VISIBLE_DEVICES=0 \
  ghcr.io/pleite/tb-vllm-toolbox:dev
```

### Flag Explanation

| Flag | Purpose |
|---|---|
| `--device /dev/dri/card1` | GPU card device (Strix Halo integrated GPU) |
| `--device /dev/dri/renderD128` | Render node for GPU rendering/compute |
| `--device /dev/kfd` | ROCm kernel fusion driver (required for GPU compute) |
| `--network host` | Required for NCCL/RCCL IBVERBS transport (UDP port 5555) |
| `--cap-add SYS_PTRACE` | Required for ROCm profiling/debugging |
| `--security-opt seccomp=unconfined` | ROCm needs relaxed seccomp |
| `--env HIP_VISIBLE_DEVICES=0` | Tells ROCm which GPU to use |

### Multi-GPU Setup

For systems with multiple GPUs, adjust `HIP_VISIBLE_DEVICES`:

```bash
# Two GPUs: 0 and 1
--env HIP_VISIBLE_DEVICES=0,1

# Specific GPU
--env HIP_VISIBLE_DEVICES=1
```

---

## Inside the Container

### 1. Load Environment

```bash
source /etc/profile.d/01-tbnet-env.sh
```

This sets:
- `TBNET_PATH=/opt/tbnet`
- `NCCL_IB_DISABLE=0`
- `NCCL_NET_GDR_LEVEL=0`
- `RCCL_IB_DISABLE=0`
- `RCCL_NET_GDR_LEVEL=0`
- Adds `/opt/tbnet/bin` to `$PATH`

### 2. Verify ROCm Devices

```bash
# Check GPU visibility
/opt/rocm/bin/rocminfo

# Check HIP device count
/opt/rocm/bin/hipInfo

# Check ROCm SMI (if available)
/opt/rocm/bin/rocm-smi --showallinfo
```

### 3. Verify tbnet Environment

```bash
echo "TBNET_PATH=$TBNET_PATH"
echo "NCCL_IB_DISABLE=$NCCL_IB_DISABLE"
echo "RCCL_IB_DISABLE=$RCCL_IB_DISABLE"
```

### 4. Run Smoke Tests

```bash
# Protocol header smoke test
/opt/tbnet/bin/proto-smoke

# Reliability smoke test
/opt/tbnet/bin/reliability-smoke

# Identity smoke test
/opt/tbnet/bin/identity-smoke

# Configuration smoke test
/opt/tbnet/bin/config-smoke
```

Expected output:
```
protocol header smoke OK
reliability smoke OK
identity smoke OK
config smoke OK
```

### 5. Verify RCCL IBVERBS Support

```bash
# Check for ibverbs symbols in librccl
nm -D /opt/rocm/lib/librccl.so.1.0 | grep -i ibv

# Expected:
# _Z15buildIbvSym...
# _Z18wrap_ibv_for...
# _Z19wrap_ibv_que...
# (multiple wrap_ibv_* functions)
```

---

## External Setup (Thunderbolt/IBVERBS)

### Prerequisites

- Thunderbolt peer-to-peer connection between two hosts
- Both hosts must have `thunderbolt_ibverbs` module loaded
- Both hosts must be in the same network namespace (or use `--network host`)

### Configure NCCL/RCCL for IBVERBS

```bash
# Set the HCA (Host Channel Adapter) name
export NCCL_IB_HCA=usb4_rdma0
export RCCL_IB_HCA=usb4_rdma0

# Set timeout and retry count
export NCCL_IB_TIMEOUT=23
export NCCL_IB_RETRY_CNT=7

# Enable GPU-direct (dma-buf path, requires CONFIG_TBV_GPU_DIRECT)
export NCCL_NET_GDR_LEVEL=3
export RCCL_NET_GDR_LEVEL=3
```

### Verify IBVERBS Devices

```bash
# List IB devices (requires thunderbolt peer-to-peer connection)
sudo ibv_devices

# Expected output:
#     device          node GUID
#     ------          ----------------
#     usb4_rdma0      0x...
```

### Launch Multi-Host Cluster

On each host:

```bash
podman run --rm -it \
  --device /dev/dri/card1 \
  --device /dev/dri/renderD128 \
  --device /dev/kfd \
  --network host \
  --cap-add SYS_PTRACE \
  --security-opt seccomp=unconfined \
  --env HIP_VISIBLE_DEVICES=0 \
  --env NCCL_IB_HCA=usb4_rdma0 \
  --env RCCL_IB_HCA=usb4_rdma0 \
  --env NCCL_NET_GDR_LEVEL=3 \
  --env RCCL_NET_GDR_LEVEL=3 \
  ghcr.io/pleite/tb-vllm-toolbox:dev
```

---

## Troubleshooting

### "No IB devices found"

This is expected if no Thunderbolt peer-to-peer connection exists. To resolve:
1. Connect two hosts via Thunderbolt cable
2. Ensure both hosts have `thunderbolt_ibverbs` loaded
3. Run `sudo ibv_devices` again

### GPU Not Visible

Check device nodes:
```bash
ls -la /dev/dri/card* /dev/dri/renderD* /dev/kfd
```

Ensure they're passed to the container via `--device` flags.

### RCCL ibverbs Symbols Missing

If `nm -D /opt/rocm/lib/librccl.so.1.0 | grep -i ibv` returns nothing:
1. Ensure the `custom_libs/` directory contains `librccl.so.1.gz`
2. Rebuild the container with RCCL artifact injected

### DKMS Build Fails

Ensure kernel headers are installed:
```bash
sudo dnf install -y kernel-devel-$(uname -r)
```

---

## Summary

| Step | Action |
|---|---|
| 1 | Install ROCm and ibverbs utilities |
| 2 | Load `thunderbolt_ibverbs` kernel module |
| 3 | Install USB4 RDMA provider RPM |
| 4 | Verify device nodes (`/dev/dri/*`, `/dev/kfd`) |
| 5 | Run `podman run` with `--device` flags |
| 6 | Load environment: `source /etc/profile.d/01-tbnet-env.sh` |
| 7 | Validate: `rocminfo`, `hipInfo`, smoke tests |
| 8 | Configure NCCL/RCCL for IBVERBS (if Thunderbolt connected) |

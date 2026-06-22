# tb-vllm-toolbox deployment model

This document clarifies how the `thunderbolt_ibverbs` kernel module, the
`usb4_rdma` libibverbs provider, and the `tb-vllm-toolbox` image interact, and
which deployment model is recommended for Strix Halo clusters.

---

## Recommended model: host-first kernel module, container userspace

The **recommended** deployment model is:

1. **Kernel module on the host.** Build + load `thunderbolt_ibverbs` on the
   host using either:
   - The upstream `make dkms-add dkms-build dkms-install` workflow (preferred), or
   - The container's `tbnet-dkms-build` helper (opt-in convenience — see below).

2. **Userspace provider in the container.** The `tb-vllm-toolbox` image ships
   the `usb4_rdma` libibverbs provider plugin so that `ibv_devices` inside the
   container enumerates `usb4_rdma*` devices that the host kernel module exposes.

3. **Container with /dev/infiniband bind-mounted.** When the toolbox is entered
   or run, `/dev/infiniband` (from the host) is exposed so the container's
   libibverbs can talk to the kernel module's char device.

### Why host-first?

- The kernel module must be compiled against the **exact** running host kernel
  (or installed via the host's `kernel-devel` package).
- Module loading, `modprobe.d` configuration, and `peer_auth_acl` PSK
  configuration are inherently host-level operations.
- The container is a userspace tool that should not need to manage kernel
  modules.

---

## Container-DKMS (opt-in convenience)

For users who want to build the kernel module **inside** the toolbox instead
of on the host, the image ships a convenience helper:

```bash
# Inside the toolbox, with /lib/modules from the host visible:
tbnet-dkms-build
```

This script:
1. Reads the staged DKMS source from `/usr/src/thunderbolt-ibverbs-<VERSION>`
2. Registers it with DKMS (`dkms add`)
3. Builds it for the running kernel (`dkms build -k $(uname -r)`)
4. Installs it (`dkms install -k $(uname -r)`)

### Requirements for container-DKMS

The toolbox must be started with the host's `/lib/modules` visible:

```bash
toolbox enter vllm-tbnet -- /bin/bash
# or for podman (read-write mount required — dkms install writes the built .ko back):
podman run --privileged -v /lib/modules:/lib/modules:rw localhost/tb-vllm-toolbox:latest
```

On the host, `kernel-devel-$(uname -r)` must be installed before running
`tbnet-dkms-build`.

After the module is built, **loading it is still a host operation**:

```bash
# On the HOST (not inside the container):
sudo modprobe thunderbolt_ibverbs \
    profile=linux_perf \
    bind_services=1 allocate_rings=1 start_rings=1 \
    negotiate_native=1 enable_tunnels=1 register_verbs=1
```

---

## Deployment checklist

### On each host (pre-requisites)

- [ ] Kernel ≥ 6.14 (Fedora 43 ships 6.14+)
- [ ] `kernel-devel-$(uname -r)` installed
- [ ] `thunderbolt-ibverbs` module built + loaded (see below)
- [ ] `peer_auth_acl` configured for peer nodes
- [ ] `/dev/infiniband` exists (created by the kernel module)

### Building the module

**Preferred (host DKMS):**
```bash
git clone https://github.com/pleite/thunderbolt-ibverbs.git
cd thunderbolt-ibverbs
sudo make dkms-add dkms-build dkms-install
sudo modprobe thunderbolt_ibverbs profile=linux_perf bind_services=1 \
    allocate_rings=1 start_rings=1 negotiate_native=1 enable_tunnels=1 \
    register_verbs=1
```

**Alternative (container-DKMS):**
```bash
toolbox enter vllm-tbnet
tbnet-dkms-build
# Then on the host:
sudo modprobe thunderbolt_ibverbs profile=linux_perf bind_services=1 \
    allocate_rings=1 start_rings=1 negotiate_native=1 enable_tunnels=1 \
    register_verbs=1
```

### After module is loaded

- [ ] `dmesg | grep thunderbolt_ibverbs` shows "native path ready"
- [ ] `ibv_devices` lists `usb4_rdma0`
- [ ] Toolbox can see devices: `toolbox enter vllm-tbnet -- ibv_devices`

### For vLLM TP=2 cluster

```bash
# In the toolbox:
source /etc/profile.d/01-tbnet-env.sh
export NCCL_IB_HCA=usb4_rdma0
export RCCL_IB_HCA=usb4_rdma0
# Then start vLLM cluster as usual
```

---

## Troubleshooting

### `ibv_devices` shows nothing inside container
- Verify the host module is loaded: `lsmod | grep thunderbolt_ibverbs`
- Verify `/dev/infiniband` is exposed to the toolbox
- The provider PABI may not match the container's libibverbs — see
  `docs/tb-vllm-toolbox-validation-log.md` for details

### `tbnet-dkms-build` fails with "Missing /lib/modules/.../build"
- Install `kernel-devel-$(uname -r)` on the host
- Restart the toolbox so `/lib/modules` is visible

### Provider RPM install fails with "IBVERBS_PRIVATE_59 not found"
- This is a known PABI mismatch between the provider RPM (built against
  rdma-core v62.0) and Fedora 43's stock libibverbs (v58.0).
- The build script falls back gracefully — the provider .so and .driver
  files are still staged in `/opt/tbnet/bin/`.
- Use `scripts/install-provider-into-container.sh` (from the host, with the
  repo checked out) to inject the staged provider into the running container:
  ```bash
  bash scripts/install-provider-into-container.sh vllm-tbnet
  ```
- Alternatively, install the provider on the **host** instead of inside the
  container.

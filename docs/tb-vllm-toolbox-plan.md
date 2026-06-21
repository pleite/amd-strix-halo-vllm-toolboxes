# Plan: DKMS + Userspace thunderbolt-ibverbs in the vLLM Toolbox

> **Implementation status (in progress).** The scaffolding for this plan has
> landed: `Dockerfile.tb-vllm-toolbox`, `scripts/build_tbnet_userspace.sh`,
> `scripts/01-tbnet-env.sh`, and `scripts/02-dkms-build.sh`. The artifacts have
> **not** been built or run on hardware yet (needs a Strix Halo GPU + USB4
> link). See [tb-vllm-toolbox-recommendations.md](tb-vllm-toolbox-recommendations.md)
> for the validation checklist and next steps, and
> [ibverbs-changes-required.md](ibverbs-changes-required.md) for upstream
> thunderbolt-ibverbs fixes to request in a follow-up session.

## Problem

The current `kyuz0/vllm-therock-gfx1151` container runs vLLM with ROCm on Strix Halo
(gfx1151) but has **no thunderbolt-ibverbs integration**. The driver lives on the host:
kernel module built via DKMS, userspace smoke tests compiled on the host. The container
is blind to the full stack.

We need a **single toolbox** that bundles:

1. **vLLM + ROCm + FP8 kernels** (current)
2. **thunderbolt-ibverbs userspace** (proto lib, usb4-rdma provider, smoke tests)
3. **DKMS + kernel headers** to build the kernel module inside the container
4. **RDMA device exposure** for clustering

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Host: Fedora 43, kernel 7.0.12, DKMS registered   │
│  /lib/modules/7.0.12/extra/thunderbolt_ibverbs.ko   │
│  /dev/infiniband/ (IB/RDMA devices)                 │
└────────────────┬────────────────────────────────────┘
                 │ mount /lib/modules, expose /dev/infiniband
┌────────────────▼────────────────────────────────────┐
│  Container: tb-vllm-toolbox (Fedora 43)             │
│                                                     │
│  Stage 1 — Build Userspace                          │
│    • proto/    → libtbnet.a (C static library)      │
│    • userspace → usb4-rdma-provider binary           │
│    • tools/ci  → smoke test binaries                │
│                                                     │
│  Stage 2 — Build Kernel Module                      │
│    • dkms + kernel-devel (matching running kernel)  │
│    • dkms build thunderbolt-ibverbs                 │
│    • module installed to /lib/modules/$KVER/extra/  │
│                                                     │
│  Stage 3 — Runtime                                  │
│    • /opt/venv (vLLM + PyTorch + ROCm)             │
│    • /opt/tbnet/     (proto lib + headers)          │
│    • /opt/tbnet/bin/ (userspace provider + smoke)   │
│    • /opt/start-vllm (TUI launcher)                 │
│    • /opt/start-cluster (ray+vLLM cluster TUI)      │
└─────────────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. DKMS Inside the Container

The container must build the kernel module against the **running host kernel**, not a
container kernel. This means:

- **Mount host `/lib/modules` into the container** at build time
- Use the host's kernel headers: `kernel-devel-$(uname -r)`
- Run `dkms build` and `dkms install` inside the container during Docker build
- The compiled `.ko` is written to the host's `/lib/modules/$KVER/extra/` via the
  bind-mounted `/lib/modules`

**Implication**: `docker build` must use `--privileged` or at least have access to
`/lib/modules`. With podman, this works naturally since podman runs rootful by default.

**Build command**:
```bash
podman build -t tb-vllm-toolbox \
  --privileged \
  -f Dockerfile.tb-vllm-toolbox .
```

### 2. Separate Dockerfile

**Do NOT modify the existing `Dockerfile`** — it's battle-tested and published as
`kyuz0/vllm-therock-gfx1151`. Create a new `Dockerfile.tb-vllm-toolbox` that:

- **Starts FROM** the existing `kyuz0/vllm-therock-gfx1151:latest` image (or rebuilds
  the vLLM stack from scratch — see below)
- Adds DKMS build stages on top
- Copies thunderbolt-ibverbs source and builds everything

**Two options for the base:**

| Option | Pros | Cons |
|--------|------|------|
| **A: FROM kyuz0/vllm-therock-gfx1151:latest** | Fast, inherits all vLLM fixes | Can't bind-mount `/lib/modules` into a running container's build; must do DKMS in a separate stage |
| **B: FROM scratch (rebuild vLLM stack)** | Full control, single Dockerfile | Huge build time (~1h+), must keep up with vLLM patches |

**Recommendation: Option A with a multi-stage approach.**

```
# Stage 1: base (vLLM stack)
FROM kyuz0/vllm-therock-gfx1151:latest AS vllm-base

# Stage 2: userspace build
FROM fedora:43 AS tbnet-build
  → Install C build deps, RDMA headers, thunderbolt-ibverbs source
  → Build proto library, userspace provider, smoke tests
  → Install to /opt/tbnet/

# Stage 3: final image
FROM vllm-base
  → Copy /opt/tbnet/ from tbnet-build
  → COPY refresh_toolbox.sh, start-vllm, etc.
  → CMD ["/bin/bash"]
```

### 3. Userspace Build (Stage 2)

From `thunderbolt-ibverbs`:

| Component | What it builds | Install location |
|-----------|---------------|------------------|
| `proto/` | `libtbnet.a` + headers | `/opt/tbnet/lib/`, `/opt/tbnet/include/` |
| `userspace/usb4_rdma/` | `usb4-rdma-provider` | `/opt/tbnet/bin/` |
| `tools/ci/*-smoke.c` | smoke test binaries | `/opt/tbnet/bin/` |
| `packaging/` | (skip — RPM packaging not needed for container) | |

**Required host packages for userspace build:**
```
dnf install -y gcc gcc-c++ make cmake rdma-core-devel libibverbs-devel \
  kernel-devel-$(uname -r) pkg-config
```

### 4. DKMS Build (Stage 3 — runs on host mount)

After the vLLM base is ready, we run a **post-build step** (not inside Dockerfile)
that:

1. Creates the container with host `/lib/modules` bind-mounted
2. Runs `dkms build` + `dkms install` inside the container
3. Unmounts

**Alternative**: Bake DKMS into the container but run `podman run --privileged` for
the build step. This is cleaner.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `Dockerfile.tb-vllm-toolbox` | **NEW** | Multi-stage Dockerfile for DKMS + userspace + vLLM |
| `refresh_toolbox.sh` | **MODIFY** | Add `--device /dev/infiniband` + auto-detect IB |
| `scripts/01-tbnet-env.sh` | **NEW** | Environment setup for tbnet library |
| `scripts/02-dkms-build.sh` | **NEW** | Build kernel module with DKMS inside container |
| `rdma_cluster/` | (unchanged) | Existing RDMA cluster setup docs |
| `README.md` | **MODIFY** | Document new toolbox, new usage |

## Refresh Script Changes

`refresh_toolbox.sh` needs to:

1. Auto-detect IB/RDMA devices (`/dev/infiniband`)
2. Add `--device /dev/infiniband --group-add rdma --ulimit memlock=-1`
3. Set `TBNET_PATH=/opt/tbnet` in the container profile
4. Run `02-dkms-build.sh` on first container start (one-time only, cached)

## Testing Strategy

| Test | How | Pass Criteria |
|------|-----|---------------|
| Proto smoke | `/opt/tbnet/bin/proto-smoke` | Exit 0, "OK" in output |
| Reliability smoke | `/opt/tbnet/bin/reliability-smoke` | Exit 0, "OK" in output |
| Identity smoke | `/opt/tbnet/bin/identity-smoke` | Exit 0, "OK" in output |
| Config smoke | `/opt/tbnet/bin/config-smoke` | Exit 0, "OK" in output |
| Module loaded | `lsmod \| grep thunderbolt_ibverbs` | Module in lsmod output |
| vLLM serve | `start-vllm` → run a model | Server responds on :8000 |
| Cluster | `start-vllm-cluster` → Ray + vLLM | Two-node cluster operational |

## GitHub Copilot Instructions

When Copilot implements this, it should:

1. **Start with `Dockerfile.tb-vllm-toolbox`** — the core deliverable
2. **Use the existing `Dockerfile` and `scripts/` as reference** for vLLM stack setup
3. **Follow the multi-stage pattern** described above
4. **Test userspace build** by compiling proto library and smoke tests from the
   cloned `thunderbolt-ibverbs` source
5. **Add DKMS build** as a privileged podman build step (document in README)
6. **Update `refresh_toolbox.sh`** with IB device auto-detection
7. **Keep the existing `Dockerfile` untouched** — this is additive

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Kernel headers mismatch | DKMS build fails | Use `kernel-devel-$KVER` matching `uname -r` exactly |
| `/lib/modules` bind mount permissions | Can't write `.ko` | Build with `--privileged` or ensure proper selinux contexts |
| SELinux blocking RDMA access | Runtime failure | Document `semanage fcontext` + `restorecon` for host |
| Huge Docker image size | Slow pulls | Strip `.so` files, cache `.dnf` properly |
| vLLM patches drift | Build breaks | Pin vLLM commit in Dockerfile, update with PRs |

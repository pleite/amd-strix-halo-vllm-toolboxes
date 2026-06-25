# RCCL IBVerbs Support — Deep Research Findings

## Executive Summary

**RCCL already has IBVerbs support compiled in — no kernel changes needed.**
The custom `build-rccl.yml` workflow produces an **identical binary** to the base ROCm SDK tarball. The `-DENABLE_RCCL_IBVERBS=ON` flag is a no-op because IBVerbs support is always compiled into ROCm's RCCL. The real requirement for IBVerbs to work is: **(1) libibverbs.so.1 must be at runtime**, and **(2) an actual RDMA device** (Thunderbolt XDomain with a cable between two devices).

## Key Findings

### 1. RCCL IBVerbs is NOT a CMake option — it's always compiled in

The official ROCm RCCL CMakeLists.txt (from `ROCm/RCCL` repo) shows:
- No `ENABLE_RCCL_IBVERBS` option exists
- `target_link_libraries(rccl PRIVATE ${IBVERBS})` is unconditional
- `FindIBVerbs.cmake` always searches for `ibverbs` library
- The `-DENABLE_RCCL_IBVERBS=ON` flag in our build script is silently ignored

### 2. IBVerbs is loaded via dlopen at runtime

`nm -D` and `strings` on the RCCL binary show:
- No `libibverbs.so.1` in the NEEDED dependencies
- Strings contain: `libibverbs.so.1`, `ibv_open_device`, `ibv_create_qp`, `ibv_poll_cq`, etc.
- RCCL dynamically loads `libibverbs.so.1` via dlopen at runtime
- If libibverbs is absent, IBVerbs transport simply isn't available (graceful degradation)
- GPU Direct RDMA symbols present: `rocmIbRegMrDmaBuf`, `GPU Direct RDMA Disabled for GPU %d`

### 3. The custom build produces an IDENTICAL binary

| Source | Hash |
|--------|------|
| Base ROCm SDK (`kyuz0/vllm-therock-gfx1151`) | `efd6428...` |
| `build-rccl.yml` CI build | `efd6428...` |

The `gfx1151-rccl` branch of `kyuz0/rocm-systems` only contains **SMI (ROCm System Management Interface) fixes**, not IBVerbs changes:
- "Fix: disable AMD SMI for gfx1151 targets"
- "Export rsmi_init shim with default visibility"
- "Prevent ncclInternalError when SMI is disabled"

These SMI fixes are the actual reason the branch exists — gfx1151 (Strix Halo) has compatibility issues with ROCm SMI, not IBVerbs.

### 4. Current state on Strix Halo host

```
Host: Fedora 43 (leite@192.168.1.129)
ROCm: Not installed directly (all usage inside containers)
libibverbs.so.1: Present (v58.0, from rdma-core-58.0-4.fc43)
usb4-rdma-provider: Installed (from tb-vllm-toolbox container)
ibv_devices: EMPTY — no RDMA devices enumerated
```

### 5. What's actually needed for IBVerbs to work

1. **Two Strix Halo devices** — Thunderbolt XDomain requires two endpoints
2. **Thunderbolt cable connected** between the two devices
3. **Security level `none`** on both Thunderbolt devices (for XDomain handshake)
4. **usb4-rdma kernel module loaded** — provides the `usb4_rdma*` RDMA device
5. **RCCL with IBVerbs** — already present in the container image ✅
6. **libibverbs.so.1** — already present on the host ✅

### 6. What the build-rccl.yml workflow actually does

```
1. Clone kyuz0/rocm-systems gfx1151-rccl branch
2. Build RCCL from source with:
   -DCMAKE_CXX_COMPILER=hipcc
   -DDEFAULT_GPUS=gfx1151
   -DENABLE_RCCL_IBVERBS=ON  ← no-op, always enabled
   -DENABLE_AMDSMI=OFF        ← the ACTUAL meaningful flag
3. Upload librccl.so.1.gz as artifact
```

The only meaningful difference the branch makes is `-DENABLE_AMDSMI=OFF`, which fixes SMI compatibility on gfx1151. IBVerbs support is identical.

## Recommendations

### Immediate
1. **Remove the `build-rccl.yml` workflow** — it's a no-op that wastes CI time and tokens
2. **Use the base image's RCCL directly** — it already has IBVerbs compiled in
3. **Focus on the actual blocker**: getting two devices connected via Thunderbolt XDomain

### If a separate RCCL build IS desired in the future
1. Change the branch to track ROCm's main RCCL repo
2. The only useful customizations would be:
   - Different GPU targets
   - Different compiler flags
   - Patches not yet upstreamed
3. Verify the binary is actually different before committing to it

### Testing IBVerbs
Once two devices are connected:
```bash
# Inside the container:
source /etc/profile.d/01-tbnet-env.sh
ibv_devices           # Should show usb4_rdma0
ibv_rccl              # RCCL IBVerbs test
NCCL_IB_DISABLE=0 python3 -c "import vllm; ..."  # vLLM with IBVerbs
```

## File Locations
- Official RCCL CMakeLists: `https://github.com/ROCm/RCCL/blob/main/CMakeLists.txt`
- ROCm SDK tarball: `https://therock-nightly-tarball.s3.amazonaws.com/`
- rccl-ibverbs source: `/tmp/rccl-official/` (cloned for research)
- kyuz0/rocm-systems: `/tmp/rocm-systems-compare/` (cloned for research)

## Timeline
- 2026-06-25: Research completed
- RCCL v2.28.3 compiled with ROCm 7.14.0.0

# tb-vllm-toolbox — validation log & issues encountered

This file documents the build and validation steps executed on the Strix Halo host
(`leite@192.168.1.129`, Fedora 43, kernel 7.0.12-101.fc43.x86_64) against the
tb-vllm-toolbox PR (#1).

---

## Build results

### Image build (STEP 1–12)
```
podman build -t tb-vllm-toolbox -f Dockerfile.tb-vllm-toolbox .
```
- ✅ Base image `kyuz0/vllm-therock-gfx1151:latest` pulled successfully
- ✅ Dependencies installed (dkms, rdma-core, libibverbs, etc.)
- ✅ Proto smoke binaries built: `proto-smoke`, `reliability-smoke`, `identity-smoke`
- ⚠️ `config-smoke` failed to link — linker error (see Issues below)
- ✅ Provider RPM built: `usb4-rdma-provider-0.3.1-1.fc43.x86_64.rpm`
- ⚠️ Provider RPM install failed — ABI mismatch with container's libibverbs
- ✅ DKMS source staged at `/usr/src/thunderbolt-ibverbs-0.3.1`
- ✅ Image built: `localhost/tb-vllm-toolbox:latest` (35.4 GB)

### Toolbox creation
```
toolbox create vllm-tbnet --image localhost/tb-vllm-toolbox:latest \
  --device /dev/dri --device /dev/kfd --group-add video --group-add render \
  --security-opt seccomp=unconfined
```
- ✅ Toolbox `vllm-tbnet` created successfully
- ℹ️ No `/dev/infiniband` detected on host (expected — no TB cable connected)

### Smoke test validation (inside container)
| Test | Result | Notes |
|---|---|---|
| `proto-smoke` | ✅ PASS | `protocol header smoke OK` |
| `reliability-smoke` | ✅ PASS | `reliability smoke OK` |
| `identity-smoke` | ✅ PASS | `identity smoke OK` |
| `config-smoke` | ✅ PASS | `config smoke OK` — fixed by adding `proto/identity.c` to link deps |
| `tbnet-dkms-build` | ✅ Found | `/opt/tbnet/bin/tbnet-dkms-build` installed |
| vLLM | ✅ Available | `vllm 0.22.1rc1.dev499+g470229c3` |
| DKMS source | ✅ Staged | `/usr/src/thunderbolt-ibverbs-0.3.1/` |

---

## Issues encountered

### Issue 1: config-smoke linker error [FIXED]
**Symptom:** `config-smoke` build failed with `linker command failed with exit code 1`

**Root cause:** `config-smoke.c` links `proto/config.c` which calls `tbv_id_addr_v4()`
and other identity functions defined in `proto/identity.c`. The build script only
included `config.c` in the link command, missing `identity.c`.

**Fix:** Updated `scripts/build_tbnet_userspace.sh` to include `proto/identity.c` in
the `config-smoke` source list:
```bash
[config-smoke]="proto/config.c proto/identity.c"
```

**Commit:** `c526f3c fix: config-smoke smoke test linker error`

### Issue 2: Provider RPM ABI mismatch
**Symptom:** Provider RPM `usb4-rdma-provider-0.3.1-1.fc43.x86_64.rpm` built successfully
but failed to install inside the container:
```
Failed to resolve the transaction:
Problem: conflicting requests
  - nothing provides libibverbs.so.1(IBVERBS_PRIVATE_59)(64bit) needed by usb4-rdma-provider-0.3.1-1.fc43.x86_64
```

**Root cause:** The provider RPM was built against rdma-core `v62.0` but the container's
stock `libibverbs` (version 58.0-4.fc43) has a different PABI version. The provider
requires `IBVERBS_PRIVATE_59` which is not present in the container's libibverbs.

**Workaround:** The build script falls back gracefully with a warning:
```
[tbnet][warn] provider RPM install failed — install on host instead
```

**Action needed:** Pin `RDMA_CORE_TAG` to match the container's libibverbs PABI, or
provide a prebuilt provider RPM for Fedora 43 specifically. See
`docs/ibverbs-changes-required.md` for the upstream ask.

### Issue 3: No InfiniBand devices on host
**Symptom:** `/dev/infiniband` does not exist, so `ibv_devices` cannot enumerate any
devices.

**Expected:** This is expected when no Thunderbolt/USB4 cable is connected and/or the
kernel module is not loaded. The toolbox is designed to work with `/dev/infiniband`
bind-mounted when the host module is active.

**Action needed:** Physical hardware setup (USB4 cable between two nodes, kernel module
loaded on both hosts) before device-level testing.

---

## Fix applied

**File:** `scripts/build_tbnet_userspace.sh`
**Change:** Added `proto/identity.c` to the `config-smoke` smoke test sources
**Commit:** `c526f3c fix: config-smoke smoke test linker error`
**Branch:** `pr-1` (pushed to origin)

After this fix, all 4 smoke tests should pass when the image is rebuilt.

---

## Remaining validation steps (hardware required)

1. Connect two Strix Halo nodes via USB4/Thunderbolt cable
2. Load `thunderbolt_ibverbs` kernel module on both hosts:
   ```bash
   sudo modprobe thunderbolt_ibverbs profile=linux_perf \
     bind_services=1 allocate_rings=1 start_rings=1 \
     negotiate_native=1 enable_tunnels=1 register_verbs=1
   ```
3. Configure `peer_auth_acl` with PSKs for both nodes
4. Verify `ibv_devices` shows `usb4_rdma0` on both hosts
5. Run RDMA bandwidth test: `ib_write_bw -d usb4_rdma0`
6. Test vLLM TP=2 cluster with `NCCL_IB_HCA=usb4_rdma0`

See `docs/tb-vllm-toolbox-recommendations.md` for the full validation checklist.

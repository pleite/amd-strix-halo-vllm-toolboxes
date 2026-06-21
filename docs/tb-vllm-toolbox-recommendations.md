# tb-vllm-toolbox — recommendations, next steps & validation checklist

Companion to [tb-vllm-toolbox-plan.md](tb-vllm-toolbox-plan.md). The plan
describes *what* to build; this file captures *how to validate it on real
hardware*, the decisions taken during implementation, and what is still open.

> **Sandbox limitation.** The artifacts in this PR (`Dockerfile.tb-vllm-toolbox`
> and `scripts/build_tbnet_userspace.sh` / `02-dkms-build.sh`) could not be
> built or run in CI: building requires the ROCm base image, a real Strix Halo
> GPU, and a Thunderbolt/USB4 link. Every step below marked **[validate]** must
> be exercised on the two-node hardware before this is declared working.

---

## Decisions taken during implementation

1. **Host-first kernel module, container-DKMS as opt-in.** The image stages the
   DKMS source under `/usr/src` and ships `tbnet-dkms-build`, but the
   recommended path is to build + load `thunderbolt_ibverbs` **on the host**
   (matches the upstream `docs/vllm-toolbox-integration.md`). Loading a module
   and the `peer_auth_acl` PSK are host operations regardless.
2. **Existing `Dockerfile` untouched.** All additions live in
   `Dockerfile.tb-vllm-toolbox` (multi-stage, `FROM` the published base) per the
   plan's "keep the existing Dockerfile untouched" constraint.
3. **`refresh_toolbox.sh` already detects `/dev/infiniband`** and adds
   `--device /dev/infiniband --group-add rdma --ulimit memlock=-1`. No change
   was needed there for RDMA exposure — the prerequisite was already in place.
4. **Provider built from source** via the upstream
   `tools/ci/distro-package-rdma.sh fedora` so the build is pinned/reproducible.
   PABI compatibility with Fedora 43's `libibverbs` is the main risk —
   see ibverbs ask #2 in [ibverbs-changes-required.md](ibverbs-changes-required.md).

---

## Hardware validation checklist

Run on the two Strix Halo nodes connected directly by a USB4/Thunderbolt cable.

### A. Image build
- [ ] **[validate]** `podman build -t tb-vllm-toolbox -f Dockerfile.tb-vllm-toolbox .`
      completes on a Strix Halo host.
- [ ] **[validate]** `/opt/tbnet/bin/` contains the proto smoke binaries and the
      `usb4-rdma-provider-*.rpm`.
- [ ] **[validate]** `ls /usr/src/thunderbolt-ibverbs-*` shows the staged DKMS tree.

### B. Userspace smoke (inside the container, no link required)
- [ ] **[validate]** `proto-smoke`, `reliability-smoke`, `identity-smoke`,
      `config-smoke` each exit `0`.

### C. Host kernel module
- [ ] **[validate]** On the host: `kernel-devel-$(uname -r)` installed, kernel ≥ 6.14.
- [ ] **[validate]** Build + install the module (host DKMS preferred):
      `git clone … && sudo make dkms-add dkms-build dkms-install`
      — **NB:** this currently fails due to the `0.1.0`/`0.3.1` version bug
      (ibverbs ask #1). Workaround: `dkms build thunderbolt-ibverbs/0.3.1`.
- [ ] **[validate]** `sudo modprobe thunderbolt_ibverbs profile=linux_perf …`
      and `dmesg | grep thunderbolt_ibverbs` shows "native path ready".

### D. Device enumeration
- [ ] **[validate]** Host: `ibv_devices` lists `usb4_rdma0`.
- [ ] **[validate]** Container: `toolbox run -c <name> -- ibv_devices` lists
      `usb4_rdma0`. If empty, the provider PABI mismatched — drop the host
      `.driver` + `.so` into the container (ibverbs ask #2).

### E. Link + RDMA counters
- [ ] **[validate]** `ib_write_bw -d usb4_rdma0` (server) / `… <peer-ip>` (client).
- [ ] **[validate]** `cat /sys/kernel/debug/thunderbolt_ibverbs/summary` counters move.

### F. vLLM TP=2 cluster
- [ ] **[validate]** `export NCCL_IB_HCA=usb4_rdma0 RCCL_IB_HCA=usb4_rdma0`
      before `start-vllm-cluster`; Force Ethernet = **NO**.
- [ ] **[validate]** Ray shows 2 nodes / 2 GPU; a TP=2 model serves on `:8000`.
- [ ] **[validate]** Compare tok/s vs TCP-over-Thunderbolt (expect ~30% faster).

---

## What is still needed to work on this system ("validate what is needed more")

| Need | Status | Owner |
|---|---|---|
| ROCm Strix Halo base image | exists (`kyuz0/vllm-therock-gfx1151`) | upstream |
| `/dev/infiniband` exposure in toolbox | done (refresh_toolbox.sh) | this repo |
| Userspace provider in container | implemented, **PABI [validate]** | this repo + ibverbs ask #2 |
| Host kernel module build | blocked by version bug | **ibverbs ask #1** |
| Two USB4-connected Strix Halo nodes, kernel ≥ 6.14 | hardware prerequisite | user |
| `peer_auth_acl` PSK + Thunderbolt UUIDs | per-host config | user (see integration guide) |
| `NCCL_IB_HCA` exported for the cluster | defaulted in `01-tbnet-env.sh`, must match device | user |
| CI to publish the `tb-vllm-toolbox` image | not yet (see next steps) | this repo |

---

## Next steps (ordered)

1. **Unblock the host module build** — file ibverbs ask #1 (version bug) and use
   the `0.3.1` workaround meanwhile.
2. **Build the image on hardware** and walk the checklist above; capture the
   `/opt/tbnet/*.log` files for any smoke build that failed.
3. **Confirm provider PABI** against Fedora 43 `libibverbs`; if mismatched, pin
   `RDMA_CORE_TAG` to the matching tag (ibverbs ask #2).
4. **Publish the image** — add a GitHub Actions workflow that builds
   `Dockerfile.tb-vllm-toolbox` and pushes a `tb-vllm-toolbox:dev` /
   `:latest` channel, mirroring `refresh_toolbox.sh`'s channel model. (Image
   publishing requires hardware-capable runners or a cross-build strategy.)
5. **Wire `refresh_toolbox.sh` to the new image** (optional) — add a
   `tb` channel / image repo once the image is published, so users can pull the
   tbnet-enabled toolbox the same way.
6. **Benchmark** and add results to `benchmarks/` / `docs/` (tok/s, bandwidth,
   latency) comparing native usb4_rdma vs TCP-over-Thunderbolt vs onboard eth.

---

## Release / housekeeping

- `CHANGELOG.md` records this addition (Keep-a-Changelog format).
- The plan doc carries an implementation-status banner pointing here.
- No GitHub Release is cut yet: the image is not built/published from CI. Cut a
  tagged release **after** step 4 above so a release corresponds to a pullable
  image.

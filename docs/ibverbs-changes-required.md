# thunderbolt-ibverbs changes to request (follow-up session)

This file records changes that belong in the **thunderbolt-ibverbs** repo
(`pleite/thunderbolt-ibverbs`, upstream `hellas-ai/thunderbolt-ibverbs`) rather
than in this toolbox repo. They were discovered while implementing the
`tb-vllm-toolbox` plan (see [tb-vllm-toolbox-plan.md](tb-vllm-toolbox-plan.md)).
Open them as issues/PRs against that repo in a separate session.

Reference revision inspected: `95c98aa4bc88a6ef3b992aa955e372573e09dce8`.

---

## 1. DKMS version mismatch between `Makefile` and `dkms.conf` (bug)

- `dkms.conf` declares `PACKAGE_VERSION="0.3.1"`.
- The top-level `Makefile` `dkms-*` targets hardcode `thunderbolt-ibverbs/0.1.0`:

  ```make
  dkms-build:   dkms build thunderbolt-ibverbs/0.1.0 -k $(KVER)
  dkms-install: dkms install thunderbolt-ibverbs/0.1.0 -k $(KVER)
  dkms-remove:  dkms remove thunderbolt-ibverbs/0.1.0 --all
  ```

`sudo make dkms-build` (as documented in the README) fails after `dkms add`,
because DKMS registers version `0.3.1` from `dkms.conf` but the targets ask for
`0.1.0`. **Ask:** derive the version from `dkms.conf`
(`$(shell awk -F'"' '/^PACKAGE_VERSION=/{print $$2}' dkms.conf)`) so the
`Makefile`, `dkms.conf`, and packaging stay in lockstep.

## 2. Container provider story: ship a Fedora provider artifact usable from the toolbox

The toolbox image is **Fedora 43**. To enumerate `usb4_rdma*` inside the
container we need the `usb4_rdma` libibverbs provider `.so` whose PABI matches
the container's `libibverbs`. Today the in-container build path is:

- `tools/ci/distro-package-rdma.sh fedora` builds the provider against
  rdma-core `v62.0` and produces an RPM. If the container's stock `libibverbs`
  PABI differs from `v62.0`, the provider may load but fail to enumerate.

**Ask one of:**

- Document / pin the rdma-core version that Fedora 43's `libibverbs` ships and
  confirm `distro-package-rdma.sh fedora` targets that PABI (add a
  `RDMA_CORE_TAG` recommendation per Fedora release), **or**
- Publish a prebuilt `usb4-rdma-provider-<ver>-1.x86_64.rpm` on GitHub Releases
  for Fedora 43 specifically (the README references `.fedora` RPMs but the
  toolbox needs to know the exact tag/codename to `dnf install` by URL), **or**
- Provide a `tools/ci/install-provider-into-container.sh` helper that drops the
  `.driver` file into `/etc/libibverbs.d/` and the `.so` into
  `/usr/lib64/libibverbs/` for an arbitrary running container (the
  vllm-toolbox-integration.md "Phase 5.1" note already hints at this manual
  fallback — promote it to a supported script).

## 3. A reusable smoke-test build target (`tools/ci/Makefile`)

The container builds the proto smoke binaries (`proto-smoke`,
`reliability-smoke`, `identity-smoke`, `config-smoke`) with ad-hoc `gcc`
invocations because there is no Makefile in `tools/ci/`. The exact set of extra
`proto/*.c` translation units each smoke test needs has to be reverse-engineered
from `#include`s.

**Ask:** add a small `tools/ci/Makefile` (mirroring `proto/Makefile`) that
builds all freestanding smoke binaries with `make -C tools/ci`. The toolbox
would then call that target instead of hardcoding the source lists in
`scripts/build_tbnet_userspace.sh`.

## 4. Confirm the intended kernel-module deployment model

There is a tension between two docs in the thunderbolt-ibverbs repo and the
plan in this repo:

- `docs/vllm-toolbox-integration.md` says **the kernel module stays on the
  host**; the container only needs the userspace provider.
- This repo's `docs/tb-vllm-toolbox-plan.md` proposes **building the kernel
  module via DKMS inside the container** against a bind-mounted `/lib/modules`.

Both can work, but they imply different "blessed" workflows. **Ask:** state the
recommended model in the integration guide (host-DKMS vs container-DKMS), and if
container-DKMS is supported, document the exact `podman run` flags
(`--privileged`, `/lib/modules` mount, `kernel-devel-$(uname -r)` on the host).
This toolbox implements the host-first model and treats container DKMS as an
opt-in convenience (`tbnet-dkms-build`).

## 5. Module load params as a copy-paste `modprobe.d` drop-in for Strix Halo

The integration guide spells out the `linux_perf` parameters and the
`peer_auth_acl=<uuid>=<psk>` requirement. **Ask:** ship a ready-to-edit
`packaging/modprobe.d/thunderbolt-ibverbs.conf.example` with the Strix-Halo
`linux_perf` defaults so users only fill in `<peer-uuid>` and `<psk>`. The
toolbox README can then point at it directly.

---

## Suggested issue titles for the follow-up session

1. `Makefile dkms-* targets hardcode 0.1.0 but dkms.conf is 0.3.1`
2. `Provide a Fedora-43-PABI usb4_rdma provider artifact for container use`
3. `Add tools/ci/Makefile to build the proto smoke binaries`
4. `Document host-DKMS vs container-DKMS deployment model`
5. `Ship a modprobe.d example for linux_perf + peer_auth_acl`

# Changelog

All notable changes to this repository are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **tb-vllm-toolbox integration (thunderbolt-ibverbs).** Additive toolbox that
  layers thunderbolt-ibverbs (tbnet) on top of the vLLM + ROCm Strix Halo image
  without touching the existing `Dockerfile`:
  - `Dockerfile.tb-vllm-toolbox` — multi-stage image `FROM` the published base
    that builds the tbnet userspace and stages the DKMS source.
  - `scripts/build_tbnet_userspace.sh` — builds the proto smoke-test binaries
    and the `usb4_rdma` libibverbs provider, and stages the DKMS source tree.
  - `scripts/01-tbnet-env.sh` — `TBNET_PATH` + NCCL/RCCL defaults profile.
  - `scripts/02-dkms-build.sh` (`tbnet-dkms-build`) — runtime DKMS build of the
    kernel module against the host kernel (opt-in; host build preferred).
- Documentation:
  - `docs/tb-vllm-toolbox-recommendations.md` — decisions, hardware validation
    checklist, "what's needed to work on this system", and next steps.
  - `docs/ibverbs-changes-required.md` — fixes to request in the
    thunderbolt-ibverbs repo (DKMS version bug, Fedora provider artifact,
    `tools/ci/Makefile`, deployment-model docs, `modprobe.d` example).
  - Implementation-status banner added to `docs/tb-vllm-toolbox-plan.md`.

### Notes
- The new image has not been built/published from CI yet (requires Strix Halo
  hardware + USB4 link). No GitHub Release is cut until the image is pullable —
  see the recommendations doc for the publishing plan.

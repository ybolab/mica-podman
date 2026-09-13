# 20260913-2211-build-env-release Build on the mica-build-env release and own the scripts

- **status**: in_progress
- **priority**: P1
- **owner**: sq6oxsf0
- **createdAt**: 2026-09-13 22:11

## Description

Adopt mica-build-env v0.0.1 (release pin, published image digests) and replace
the shared source pin and producer framework with this repository's own build,
package and gate scripts per the release's RULES.md, keeping the deb package as
the only output. Plan: `docs/plan/20260913-2211-build-env-release.md`.

## ActiveForm

Moving mica-podman onto the mica-build-env release

## Dependencies

- **blocked by**: (none)
- **blocks**: (none)

## Notes

- Release v0.0.1, tag commit 4d90e5cadb3e0f83ed295f59d1ef0df0cfcfc04b, SHA256SUMS
  sha256 c3380f58e8409c1c6b79788270e554abe6146de0173bfb1ebccca2e046f3d7dd.
- Implemented in b07b1f4. Local: `make check`; `make pool` and `make package-gate`
  (25/25, no-cache rebuilds byte-identical) over the existing binaries on the
  release base image.
- CI run 34786573028 on b07b1f4: engine built from source on native amd64 and
  arm64 runners on the four release digests, 12/12 gate per architecture with
  no-cache rebuild, 23/23 cross-architecture gate. Artifacts:
  mica-podman_5.8.6+gitb07b1f48b473-1_amd64.deb sha256 dc7bc7c2...18ccac,
  mica-podman_5.8.6+gitb07b1f48b473-1_arm64.deb sha256 d4afe52b...48cf70.
- Waiting on two decisions (plan, "Decisions left open"): the publication
  channel and the package version number.

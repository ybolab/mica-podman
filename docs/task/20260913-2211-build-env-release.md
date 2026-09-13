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
- Decisions resolved by coordinator a0psyi7e: OCI pool channel, version
  `<PODMAN_VERSION>+git<commit12>-1`; VERSION removed (plan, "Decisions").
- d8394e8: tools/publish.sh + publish job. tests/publish-test.sh 14/14 on local
  registries; mutations (identity annotations dropped, credentialed read-back)
  are caught.
- CI run 34787482160 on d8394e8: check, package amd64/arm64, gate succeed;
  publish uploaded pool.amd64.build-d8394e8b5688 (manifest sha256:a3af00bd...,
  deb sha256:e91ddd66...) and pool.arm64.build-d8394e8b5688 (manifest
  sha256:4757d0f5..., deb sha256:f92c5fde...), then stopped: anonymous token
  endpoint HTTP 401, package private. Not published; the tags remain.
- User direction 22:45 (via a0psyi7e): packages need not use OCI. The channel
  becomes the GitHub Release build-<commit12> (tools/release.sh,
  tests/release-test.sh 13/13); the OCI publisher is removed.

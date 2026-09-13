# 20260913-2211-build-env-release Build on the mica-build-env release and own the scripts

- **status**: implementing
- **createdAt**: 2026-09-13 22:11
- **approvedAt**: 2026-09-13 (coordinator a0psyi7e handoff of build-env v0.0.1; user direction: deb package is the only output, keep /usr/bin/docker)
- **relatedTask**: 20260913-2211-build-env-release

## Context

The repository consumed mica-build-env as a source pin (`tools/deps.sh`,
`deps/sources/mica-build-env.json`, `build-env/`), built on locally built
`localhost/mica-build-*` images and packed through the shared producer
framework (`build-env/deb/{build,pack,repo,preflight,package-gate,publish}.sh`).
build-env now delivers versioned releases (v0.0.1: source archive, `images.env`,
`SHA256SUMS`) and public images; each repository implements `RULES.md` in its
own scripts.

## Proposal

1. Pin the release: `build-env.env` records `MICA_BUILD_ENV_VERSION` and the
   sha256 of `SHA256SUMS`. `tools/build-env.sh fetch` downloads the three
   assets into `_out/build-env/v<version>/`, refuses `SHA256SUMS` unless it
   hashes to the pin, then `sha256sum -c` and the archive top directory.
   `tools/build-env.sh image <IMAGE_MICA_BUILD_*>` prints a validated digest pin
   from the verified `images.env`.
2. Build on the published images: `build.sh` passes
   `IMAGE_MICA_BUILD_{BASE,C,GO,RUST}` to `Dockerfile`; the src stage uses the
   base index at the build platform, so the native-base argument and the OCI
   layout contexts go. Builder selection moves to `tools/buildx.sh`.
3. Own packaging: `deb/` holds the control template, copyright, payload
   manifest, `Dockerfile` (on `IMAGE_MICA_BUILD_BASE`) and `pack.sh` (RULES
   section 6). `tools/package.sh --arch` checks `_out/podman/<arch>`
   (binaries, stamp, ELF architecture), derives
   `<PODMAN_VERSION>+git<commit12>[.dirty]-1`, `SOURCE_DATE_EPOCH` (HEAD commit
   time) and provenance, and writes `_out/debs/<arch>/`.
4. Own gate: `tests/package-gate.sh` checks each archive's identity fields,
   one stamp across arches, copyright, no conffiles, maintainer scripts,
   Replaces or enablement links, the payload against `payload.manifest`, and
   with `--reproduce` a no-cache rebuild byte for byte.
5. CI: `make check`, then per-architecture native runners build, pack and
   reproduce, then a gate over both arches; a push to main publishes those
   gated artifacts with `tools/publish.sh` (packages: write), never cancelled
   halfway.
6. Publish (RULES section 3): `tools/publish.sh` pushes
   `ghcr.io/ybolab/mica-podman:pool.<arch>.build-<commit12>` from a clean
   HEAD: one `application/vnd.mica.deb` layer titled
   `mica-podman_<version>_<arch>.deb`, empty config, `artifactType
   application/vnd.mica.pool`, annotations revision, created (commit time,
   UTC), source, `mica.source-repo`, `mica.source-commit`, `mica.arch`. Every
   archive's identity is checked before any registry access; an existing tag
   must match bytes and identity; both pools are uploaded, then each manifest
   (by tag and digest) and deb is read back with no credential.
   `tests/publish-test.sh` drives it against local registries.
7. Remove what no caller needs any more: `tools/deps.sh`, `deps/`,
   `build-env/`, `deb/podman/producer.env` and `prepare.sh`, the `make
   build-env` image build and the pool index.

Verification: `make check` (including new `build-env-test`, `stamp-test`);
`make pool` and `make package-gate` over the existing `_out/podman/{amd64,arm64}`
binaries on the release base image; CI run on both native arches.

## Decisions

- Publication channel (coordinator a0psyi7e, 2026-09-13, project contract and
  the Core/Podman publication grant): the own-repository OCI pool of RULES
  section 3. No GitHub Release channel.
- Package version (same): this repository keeps
  `<PODMAN_VERSION>+git<commit12>-1`; `versions.env` `PODMAN_VERSION` is the one
  version input. The unused `VERSION` file is removed.

## Risks

- The engine is rebuilt on new base images; the first CI run is the build
  evidence, local binaries predate the release images.
- arm64 runners (`ubuntu-24.04-arm`) must be available to the repository.

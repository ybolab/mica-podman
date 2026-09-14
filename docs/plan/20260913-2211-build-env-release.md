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
5. CI: `build.yml` (reusable) runs `make check`, per-architecture native
   builds with a no-cache reproduction and a gate over both arches. `ci.yml`
   calls it on pushes and pull requests and publishes nothing; `release.yml`
   is manual only (workflow_dispatch on main), calls it and releases those
   gated artifacts with `tools/release.sh` (contents: write), never cancelled.
6. Release: `tools/release.sh` publishes the gated archives of a clean HEAD
   on main as the GitHub Release `<YYYYMMDD-HHMM>` (UTC, now), created with
   `--target <commit>`: `mica-podman_<version with + as .>_<arch>.deb` for
   amd64 and arm64 and `SHA256SUMS` over both. Archive identity is checked
   before any gh call; the name must not exist as a release or tag and must be
   after the newest release, and no release may already carry these archives;
   then the tag and every asset are read back anonymously.
   `tests/release-test.sh` drives it against a stub gh.
7. Remove what no caller needs any more: `tools/deps.sh`, `deps/`,
   `build-env/`, `deb/podman/producer.env` and `prepare.sh`, the `make
   build-env` image build and the pool index.

Verification: `make check` (including new `build-env-test`, `stamp-test`);
`make pool` and `make package-gate` over the existing `_out/podman/{amd64,arm64}`
binaries on the release base image; CI run on both native arches.

## Decisions

- Publication channel: first the own-repository OCI pool of RULES section 3
  (coordinator a0psyi7e); d8394e8 uploaded pool.{amd64,arm64}.build-d8394e8b5688
  and stopped because the GHCR package is private. The user's 22:45 direction
  lifts the OCI requirement for packages, so the channel is the GitHub Release
  of this public repository; the OCI publisher is removed (it stays in
  d8394e8) and the uploaded tags are left untouched.
- Release trigger and name (user, 2026-09-14): as in mica-build-env, releasing
  is manual only, with CI split out; the release name is the UTC date and
  time `<YYYYMMDD-HHMM>` instead of `build-<commit12>`. Earlier `build-*`
  releases stay as they are.
- Package version (same): this repository keeps
  `<PODMAN_VERSION>+git<commit12>-1`; `versions.env` `PODMAN_VERSION` is the one
  version input. The unused `VERSION` file is removed.

## Risks

- The engine is rebuilt on new base images; the first CI run is the build
  evidence, local binaries predate the release images.
- arm64 runners (`ubuntu-24.04-arm`) must be available to the repository.

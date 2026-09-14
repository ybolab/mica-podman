# Changelog

## 2026-09-14 00:50 [progress]

CI and releases are split as in mica-build-env. `ci.yml` builds and gates
pushes and pull requests (and runs the weekly pin check) and publishes nothing;
`release.yml` is dispatched by hand on main, builds and gates through the
shared `build.yml`, and `tools/release.sh` creates the GitHub Release
`<YYYYMMDD-HHMM>` (UTC) at that commit. It refuses a commit not on main, an
existing name, a name not after the newest release and a commit already
released. The `build-<commit12>` releases stay.

## 2026-09-14 00:20 [progress]

Publishing is manual: only a `workflow_dispatch` run of the `release` workflow
on main releases the archives; pushes and pull requests build and gate only.
The weekly pin check no longer runs on a manual run.

## 2026-09-14 00:00 [progress]

mica-build-env republished v0.0.1 at tag commit 3863d69d382a (new SHA256SUMS
de740ff5..., new base, c, go and rust image digests; RULES now allow a GitHub
Release transport). `build-env.env` pins the republished release; the old
checksum no longer verifies. The engine is rebuilt on the new images and
released as `build-<commit12>`.

## 2026-09-13 23:40 [progress]

Packages may be delivered without OCI (user direction 22:45), and the GHCR
package stays private, so the archives are released as the GitHub Release
`build-<commit12>` by `tools/release.sh` in the `publish` job. `tools/publish.sh`
and its test are removed; the pool tags d8394e8 uploaded to GHCR are left as
they are.

## 2026-09-13 23:10 [progress]

`tools/publish.sh` publishes the gated archives as
`ghcr.io/ybolab/mica-podman:pool.<arch>.build-<commit12>` (RULES section 3),
run by the `publish` job of the `release` workflow on pushes to main, which
are no longer cancelled by a later push. The package version stays
`<PODMAN_VERSION>+git<commit12>-1` with `versions.env` as its only input; the
unused `VERSION` file is removed.

## 2026-09-13 22:50 [progress]

Builds on the mica-build-env release v0.0.1 (`build-env.env`: version and
SHA256SUMS sha256 c3380f58...) and its `IMAGE_MICA_BUILD_{BASE,C,GO,RUST}`
digest pins, verified by `tools/build-env.sh`. The shared source pin
(`tools/deps.sh`, `deps/`, `build-env/`) and producer framework
(`deb/podman/producer.env`, `prepare.sh`) are removed: `tools/package.sh`,
`deb/pack.sh` and `tests/package-gate.sh` pack and gate the archive on the
release base image. CI builds each architecture on a native runner and keeps
the archives as workflow artifacts; the publication channel is an open
decision. Task `20260913-2211-build-env-release`.

## 2026-09-13 21:00 [progress]

Mica OS is the only name. The configuration uses `/mica/containers` (storage,
image copy tmp, network definitions) and the Quadlet mount requires it; the
buildx fallback builder is `mica-<arch>`. `mica-podman` is maintained by
`Mica OS <hi@micaos.dev>`, and the copyright header names Mica OS
(`tests/package-test.sh` checks both and that the retired name is gone). The
historical release transport (`tools/transport-pool.sh`, its test and
workflow) is removed: the package archives pushed by `release` are this
repository's only publication. Comments across the tree are cut to the
non-obvious constraints.

## 2026-09-13 20:00 [progress]

The pool moves to the per-repository OCI package
`ghcr.io/ybolab/mica-podman:pool.<arch>.build-<commit12>`. The substrate pin
is `mica-build-env` c076e2410326 (an OCI source artifact, read anonymously),
with `tools/deps.sh` vendored verbatim from it. The archives consumers
already pin, published only as the GitHub Release `build-4c84b4b13e03`, are
carried byte for byte into that package by `tools/transport-pool.sh`, run
only by the manual workflow `transport-pool`: each archive must hash to the
pinned digest and carry the revision's control identity before the
substrate's `deb/publish.sh` pushes it from a worktree of that revision.
`make check` runs its refusals (`tests/transport-pool-test.sh`).

## 2026-09-13 01:30 [progress]

Created from `pkgs/podman/` of `ybolab/mica-build` (5 commits kept through
`git subtree split`, then the tree at the Mica OS rename). The container
configuration and the Quadlet mount unit (`overlay/`) moved in from the
assembly's common overlay, as PLAN-036 section 3 assigns them to
`mica-podman`; `tests/podman-pins/` and its driver moved in with the check
they exercise. `versions.env` now ships in the payload as
`/usr/share/mica-podman/versions.env`, so the assembly's tests read the
engine's expected versions out of the archive they install. The substrate is
the `mica-build-env` source pin at `build-env/`; the package is published as
`build-<commit12>` and imported by `mica-build` through
`deps/packages/mica-podman.json` (Phase 3 of
`20260911-2006-split-package-repositories`).

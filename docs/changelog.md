# Changelog

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

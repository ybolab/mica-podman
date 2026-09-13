## Project Development

This repository follows the PMA workflow. The actual rules live in the `/pma`
skill — do not duplicate them here. If a rule in this file ever conflicts
with `/pma`, treat `/pma` as the source of truth and update this file.

### Skill stack

- `/pma` — workflow control, three-phase gate, task and plan tracking

The tree is bash and Dockerfiles; no stack skill covers them, and `/pma`'s
*Delivery* rules apply directly.

### Triggers

Any feature, bug fix, refactor, planning, progress tracking, or multi-agent
execution goes through `/pma` (investigate → proposal → implement). Ceremony
is tiered by complexity per `/pma` *Task Tiers*: only trivial changes take
the fast path; everything else waits for explicit approval such as `proceed`.

### Project-specific facts

- Primary language: bash (`set -euo pipefail`, no `grep -q` on the right of a pipe) and Dockerfiles; the engine itself is upstream Go, C and Rust, compiled from the tags `versions.env` pins
- The build environment is the mica-build-env release pinned in `build-env.env` (version and SHA256SUMS sha256), fetched and verified by `tools/build-env.sh` into `_out/build-env/`; builds run on its `IMAGE_MICA_BUILD_*` digest pins, and this repository implements the release's `RULES.md` in its own scripts
- The product of this repository is one Debian package, `mica-podman`, versioned `<PODMAN_VERSION>+git<commit12>[.dirty]-1` (`versions.env` `PODMAN_VERSION` is the only version input; there is no `VERSION` file), packed by `tools/package.sh` into `_out/debs/<arch>/`. It is the only output: the `release` workflow publishes the gated archives of a push to main with `tools/publish.sh` as `ghcr.io/ybolab/mica-podman:pool.<arch>.build-<commit12>`, read back anonymously
- Quality gates: `make check` (lint, `podman-pins-test`, `stamp-test`, `build-env-test`, `package-test`, `publish-test` with docker); `make pool` then `make package-gate` (no-cache rebuilds) over the archives; `make podman-pins` asks upstream whether the pins are current
- Build resources: no fixed CPU, memory or job quotas; use the host and tool defaults

### Documentation entry points

- Tasks: `docs/task/index.md`
- Plans: `docs/plan/index.md`
- Changelog: `docs/changelog.md`
- Design and project management for the whole of Mica OS: `ybolab/mica`

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
- The build substrate is `build-env/`, the `mica-build-env` source pin (`deps/sources/mica-build-env.json`, fetched by `make deps`); `build.sh` and the producer under `deb/podman/` derive the repository root as their own directory and refuse a missing substrate by name
- The product of this repository is one Debian package, `mica-podman`, versioned `<PODMAN_VERSION>+git<commit12>-1` (`VERSION` is the substrate's required repository version and is not what the archive carries), published as the GitHub Release `build-<commit12>` of `ybolab/mica-podman` by `make publish` (or the workflow) and imported by the assembly (`mica-build`) through `deps/packages/mica-podman.json`
- Quality gates: `make check` (lint, `podman-pins-test`, preflight) offline; `make pool` then `make package-gate` over the built archives; `make podman-pins` asks upstream whether the pins are current
- Build resources: no fixed CPU, memory or job quotas; use the host and tool defaults

### Documentation entry points

- Tasks: `docs/task/index.md`
- Plans: `docs/plan/index.md`
- Changelog: `docs/changelog.md`
- Design and project management for the whole of Mica OS: `ybolab/mica`

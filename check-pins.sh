#!/usr/bin/env bash
# Fail when a versions.env pin has a newer upstream release. Reads, never writes.
#
#   bash check-pins.sh                    # live, needs network
#   bash check-pins.sh --releases-dir DIR # against recorded JSON
#
# The tag prefix is taken from the pin (crun has no `v`); podman is compared
# within its pinned major; release age is never a verdict.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSIONS_ENV="${HERE}/versions.env"
RELEASES_DIR=""

usage() {
    cat >&2 <<'USAGE'
usage: check-pins.sh [--releases-dir DIR] [--versions-env FILE]

  --releases-dir DIR   read DIR/<component>.json instead of fetching from
                       GitHub; the fixture path used by the test suite
  --versions-env FILE  read FILE instead of the versions.env next to this
                       script

Exit status: 0 every pin is current, 1 at least one pin is behind, 2 the check
could not be carried out (a missing pin, an unreachable upstream, a component
with nothing comparable to compare against).
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --releases-dir) RELEASES_DIR="${2:?--releases-dir needs a directory}"; shift 2 ;;
        --versions-env) VERSIONS_ENV="${2:?--versions-env needs a file}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
done

[ -f "${VERSIONS_ENV}" ] || { echo "error: ${VERSIONS_ENV} not found" >&2; exit 2; }

# component | versions.env variable | upstream repository | line policy
COMPONENTS=(
    "podman|PODMAN_VERSION|containers/podman|line"
    "crun|CRUN_VERSION|containers/crun|newest"
    "conmon|CONMON_VERSION|containers/conmon|newest"
    "netavark|NETAVARK_VERSION|containers/netavark|newest"
    "aardvark-dns|AARDVARK_VERSION|containers/aardvark-dns|newest"
    "catatonit|CATATONIT_VERSION|openSUSE/catatonit|newest"
)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if [ -n "${RELEASES_DIR}" ]; then
    [ -d "${RELEASES_DIR}" ] || { echo "error: --releases-dir ${RELEASES_DIR} is not a directory" >&2; exit 2; }
    echo "reading recorded upstream responses from ${RELEASES_DIR} (no network)"
else
    # -L: containers/podman answers 301. -f: a rate limit is a failed check.
    echo "asking six upstreams for their releases"
    for row in "${COMPONENTS[@]}"; do
        IFS='|' read -r name _var repo _policy <<< "${row}"
        headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
        [ -z "${GITHUB_TOKEN:-}" ] || headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        curl -fsSL --max-time 60 \
            "${headers[@]}" \
            "https://api.github.com/repos/${repo}/releases?per_page=100" \
            -o "${WORK}/${name}.json" \
            || { echo "error: could not read releases for ${repo}. The check did not run; this is not a pass." >&2; exit 2; }
    done
    RELEASES_DIR="${WORK}"
fi

rc=0
python3 - "${VERSIONS_ENV}" "${RELEASES_DIR}" "${COMPONENTS[@]}" <<'PY' || rc=$?
import json
import os
import re
import sys

versions_env, releases_dir = sys.argv[1], sys.argv[2]
rows = [r.split("|") for r in sys.argv[3:]]

# Parsed, not sourced.
pins = {}
with open(versions_env, encoding="utf-8") as fh:
    for line in fh:
        m = re.match(r"^([A-Z0-9_]+)=(\S+)\s*$", line)
        if m:
            pins[m.group(1)] = m.group(2)

TAG_CORE = re.compile(r"^(\d+(?:\.\d+)*)$")


def core(tag, prefix):
    """The dotted-numeric core of TAG when it carries exactly PREFIX, else None."""
    if not tag.startswith(prefix):
        return None
    m = TAG_CORE.match(tag[len(prefix):])
    return tuple(int(p) for p in m.group(1).split(".")) if m else None


def newer(a, b):
    """Numeric, component-wise, zero-padded: 1.10 is above 1.9, and 1.29 below 1.29.1."""
    width = max(len(a), len(b))
    return a + (0,) * (width - len(a)) > b + (0,) * (width - len(b))


def show(v):
    return ".".join(str(p) for p in v)


behind, errors, notes = [], [], []
lines = []

for name, var, repo, policy in rows:
    pin = pins.get(var)
    if not pin:
        errors.append(f"{name}: {var} is not set in {versions_env}")
        continue

    prefix = re.match(r"^\D*", pin).group(0)
    pin_core = core(pin, prefix)
    if pin_core is None:
        errors.append(f"{name}: pinned tag '{pin}' is not <prefix><dotted numbers>; this check cannot compare it")
        continue

    path = os.path.join(releases_dir, f"{name}.json")
    try:
        with open(path, encoding="utf-8") as fh:
            releases = json.load(fh)
    except (OSError, ValueError) as exc:
        errors.append(f"{name}: cannot read {path}: {exc}")
        continue
    if not isinstance(releases, list) or not releases:
        errors.append(f"{name}: {path} holds no releases; an upstream with no releases is a failed read, not a current pin")
        continue

    published = {}
    comparable, skipped = {}, 0
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        tag = rel.get("tag_name") or ""
        c = core(tag, prefix)
        if c is None:
            skipped += 1
            continue
        comparable[c] = tag
        published[c] = (rel.get("published_at") or "")[:10]

    if not comparable:
        errors.append(
            f"{name}: none of {len(releases)} upstream releases carry the pin's tag convention "
            f"('{prefix}' + dotted numbers, as in '{pin}'); {skipped} were skipped. Either upstream "
            f"changed how it tags or the pin did, and comparing nothing is not a pass"
        )
        continue

    in_line = comparable
    if policy == "line":
        in_line = {c: t for c, t in comparable.items() if c[0] == pin_core[0]}
        if not in_line:
            errors.append(f"{name}: no upstream release is on the pinned {pin_core[0]}.x line, which '{pin}' claims to be on")
            continue
        outside = [c for c in comparable if c[0] > pin_core[0]]
        if outside:
            top = max(outside)
            notes.append(
                f"{name}: upstream also maintains {comparable[top]} on the {top[0]}.x line. "
                f"Which line to be on is versions.env's decision, not this check's; the pin stays on {pin_core[0]}.x"
            )

    if pin_core not in comparable:
        errors.append(
            f"{name}: the pinned tag '{pin}' is not among upstream's {len(comparable)} comparable releases. "
            f"A pin upstream does not publish cannot be checked for freshness"
        )
        continue

    top = max(in_line)
    if newer(top, pin_core):
        behind.append((name, pin, comparable[top], published.get(top, "?"), policy, pin_core[0]))
        lines.append(f"BEHIND     {name:<13} {pin:<10} -> {comparable[top]} ({published.get(top, '?')})")
    else:
        scope = f"newest on the {pin_core[0]}.x line" if policy == "line" else "newest upstream release"
        lines.append(f"UNCHANGED  {name:<13} {pin:<10} {scope}, released {published.get(pin_core, '?')}"
                     + (f", {skipped} tag(s) skipped as a different convention" if skipped else ""))

print()
for line in lines:
    print(line)
for note in notes:
    print(f"NOTE       {note}")
print()

if len(lines) + len(errors) != len(rows):
    errors.append(f"internal: {len(rows)} components declared but {len(lines) + len(errors)} accounted for")

sys.stdout.flush()

if errors:
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    print(f"RESULT: FAILED ({len(errors)} component(s) could not be checked)", file=sys.stderr)
    sys.exit(2)

if behind:
    print(f"RESULT: BEHIND ({len(behind)} of {len(rows)} pins have a newer upstream release)", file=sys.stderr)
    print(file=sys.stderr)
    for name, pin, newest, date, policy, major in behind:
        scope = f" on the {major}.x line" if policy == "line" else ""
        print(f"  {name}: pinned at {pin}, upstream released {newest} on {date}{scope}.", file=sys.stderr)
    print(file=sys.stderr)
    print("  To act on this: in versions.env set the component's *_VERSION to the", file=sys.stderr)
    print("  newer tag, set its *_SHA256 to the literal string PENDING, and run `make podman`. The", file=sys.stderr)
    print("  build prints the hash it computed and fails; paste it in and run `make podman` again.", file=sys.stderr)
    print("  Nothing here edits versions.env for you: moving a pin is a human act.", file=sys.stderr)
    sys.exit(1)

print(f"RESULT: PASS (all {len(rows)} pins are at their newest applicable upstream release)")
PY

exit "${rc}"

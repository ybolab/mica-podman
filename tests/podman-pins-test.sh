#!/usr/bin/env bash
# Drive check-pins.sh against recorded upstream responses.
#
#   bash tests/podman-pins-test.sh
#
# The check itself needs the network and runs weekly in the privileged CI lane.
# This suite needs none: `--releases-dir` feeds it JSON recorded from the GitHub
# releases API on 2026-08-29, and `--versions-env` feeds it pin files under
# tests/podman-pins/versions-env/. Every assertion below is therefore
# reproducible on a disconnected machine, and none of them writes to
# versions.env.
#
# What is NOT proved here, stated rather than implied: that GitHub still answers
# on those URLs, and that a live fetch parses. Only a networked run proves that,
# and the weekly job is where it happens. What IS proved here is every branch of
# the comparison -- which is where the interesting failures live, because the
# fetch either works or reports its own HTTP error.
#
# THE CATATONIT CASE IS WHY THIS FILE EXISTS. Its newest release is v0.2.1, from
# 2024-12-14, and versions.env calls that cadence rather than abandonment. A
# check that quietly treated catatonit as always-green -- by age, by an
# exception, by never reaching it -- would pass the green case forever and would
# never be noticed. So catatonit is asserted in BOTH directions: green while
# upstream is quiet and the pin is current, and RED the moment a recorded
# response says v0.3.0 shipped.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
CHECK="${REPO_ROOT}/check-pins.sh"
FIX="${HERE}/podman-pins"
REAL_ENV="${REPO_ROOT}/versions.env"

[ -x "${CHECK}" ] || { echo "error: ${CHECK} is missing or not executable" >&2; exit 1; }
[ -d "${FIX}/releases" ] || { echo "error: ${FIX}/releases not found; there is nothing to drive the check with" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS_N=0
FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $1"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $1"; }

# A case is a releases directory (the recording, plus zero or more per-component
# overrides copied over it) and a versions.env. Overrides are copied rather than
# a second full recording kept, so the six responses have exactly one home.
run_case() {
    local label="$1" env_file="$2" override="$3"
    local dir="${WORK}/${label}"
    mkdir -p "${dir}"
    cp "${FIX}/releases"/*.json "${dir}/"
    if [ -n "${override}" ]; then
        local src="${FIX}/overrides/${override%%:*}"
        local dest="${dir}/${override#*:}.json"
        [ -f "${src}" ] || { echo "error: override ${src} not found" >&2; exit 1; }
        cp "${src}" "${dest}"
    fi
    OUT_FILE="${WORK}/${label}.out"
    set +e
    bash "${CHECK}" --releases-dir "${dir}" --versions-env "${env_file}" >"${OUT_FILE}" 2>&1
    RC=$?
    set -e
}

# Asserts on the combined stdout+stderr of the last run_case.
expect_rc() {
    if [ "${RC}" -eq "$1" ]; then pass "$2 (exit ${RC})"; else
        fail "$2: expected exit $1, got ${RC}"
        sed 's/^/    /' "${OUT_FILE}"
    fi
}
expect_says() {
    if grep -c -- "$1" "${OUT_FILE}" >/dev/null; then pass "$2"; else
        fail "$2: output does not contain '$1'"
        sed 's/^/    /' "${OUT_FILE}"
    fi
}
expect_silent() {
    if grep -c -- "$1" "${OUT_FILE}" >/dev/null; then
        fail "$2: output should not contain '$1'"
        sed 's/^/    /' "${OUT_FILE}"
    else pass "$2"; fi
}

echo "--- 1. the tree as it stands is green"
# Criterion 1, against the REAL versions.env and the recorded responses. This is
# also the whole tag-convention assertion in the green direction: crun's pin
# carries no `v` and the other five do, and all six have to land UNCHANGED.
run_case current "${REAL_ENV}" ""
expect_rc 0 "the six pins in versions.env are current"
expect_says "RESULT: PASS" "the run says PASS"
for c in podman crun conmon netavark aardvark-dns catatonit; do
    expect_says "UNCHANGED  ${c} " "${c} is reported UNCHANGED by name"
done
# aardvark-dns's recording carries `v1.10.1-rhel`, a distro tag that is not the
# pin's convention. It must be skipped AND counted, not silently dropped.
expect_says "tag(s) skipped as a different convention" "a tag outside the pin's convention is skipped visibly"

echo
echo "--- 2. podman's 5.x line is respected, not overruled by 6.x"
# The recording holds v6.1.0. A check that compared against the newest tag
# would call a correct pin behind, every week, until somebody switched it off.
expect_silent "BEHIND     podman" "podman is not called behind because a 6.x line exists"
expect_says "upstream also maintains v6.1.0 on the 6.x line" "the newer line is reported as a note"
expect_says "versions.env's decision, not this check's" "the note says whose decision the line is"

echo
echo "--- 3. the catatonit case: quiet upstream, correctly pinned"
# Green above. Here is the other direction: the same pin, a recording in which
# upstream finally moved. Without this, "catatonit is green" would be
# indistinguishable from "catatonit is never actually compared".
expect_says "catatonit     v0.2.1     newest upstream release, released 2024-12-14" \
    "a 2024 release date is reported, not read as a failure"
run_case catatonit-moved "${REAL_ENV}" "catatonit-moved.json:catatonit"
expect_rc 1 "catatonit goes red the moment upstream publishes v0.3.0"
expect_says "BEHIND     catatonit     v0.2.1     -> v0.3.0" "the red names catatonit, its pin and the newer tag"

echo
echo "--- 4. a pin edited backwards is red and says which"
# Criteria 2 and 3, for a v-prefixed component.
run_case behind-conmon "${FIX}/versions-env/behind-conmon.env" ""
expect_rc 1 "a conmon pin behind upstream fails the run"
expect_says "conmon: pinned at v2.1.13, upstream released v2.2.1" "the failure names the component, its pin and the newer tag"
expect_says "versions.env set the component's \*_VERSION" "the failure text says to edit versions.env"
expect_says "run \`make podman\`" "the failure text says to re-run make podman"
expect_says "PENDING" "the failure text carries versions.env's own hash procedure"
expect_says "moving a pin is a human act" "the failure text refuses to do the edit itself"
expect_silent "BEHIND     crun" "only the component that moved is reported behind"

echo
echo "--- 5. the same, for the pin that carries no v"
# crun tags `1.29.1`. Comparison is numeric, so 1.28 must read as below 1.29.1
# rather than above it, which a string comparison would get backwards.
run_case behind-crun "${FIX}/versions-env/behind-crun.env" ""
expect_rc 1 "a crun pin behind upstream fails the run"
expect_says "crun: pinned at 1.28, upstream released 1.29.1" "the unprefixed convention compares numerically"

echo
echo "--- 6. behind WITHIN the pinned line"
# A 5.x pin behind a newer 5.x must be red -- the line policy narrows the
# comparison, it does not disable it.
run_case behind-podman-line "${FIX}/versions-env/behind-podman-line.env" ""
expect_rc 1 "a podman pin behind a newer 5.x release fails the run"
expect_says "podman: pinned at v5.8.3, upstream released v5.8.6" "the newer tag reported is the 5.x one"
expect_says "on the 5.x line" "the failure says which line it compared within"
expect_silent "released v6" "the 6.x line is never offered as the fix"

echo
echo "--- 7. prereleases and drafts are not releases"
# A recording where the only things above the pin are an rc and a draft. Green:
# neither is something versions.env would pin.
run_case catatonit-prerelease "${REAL_ENV}" "catatonit-prerelease-only.json:catatonit"
expect_rc 0 "an rc and a draft above the pin do not make it behind"
expect_silent "v0.3.0-rc1" "the rc is not offered as a newer release"

echo
echo "--- 8. the check fails rather than passes when it cannot compare"
# Three ways to end up comparing nothing. Each has to be an error (exit 2), not
# a green: a check that reports PASS over an empty set is the failure mode this
# whole file exists to prevent.
run_case reconventioned "${REAL_ENV}" "crun-reconventioned.json:crun"
expect_rc 2 "an upstream that changed its tag convention is an error, not a pass"
expect_says "changed how it tags or the pin did" "the error names the convention mismatch"

run_case empty "${REAL_ENV}" "catatonit-empty.json:catatonit"
expect_rc 2 "an upstream that returns no releases is an error, not a pass"
expect_says "holds no releases" "the error says the read came back empty"

run_case unknown-pin "${FIX}/versions-env/unknown-pin.env" ""
expect_rc 2 "a pin upstream does not publish is an error, not a pass"
expect_says "is not among upstream's" "the error names the unpublished pin"

run_case missing-pin "${FIX}/versions-env/missing-pin.env" ""
expect_rc 2 "a versions.env missing a pin is an error, not a pass"
expect_says "CATATONIT_VERSION is not set" "the error names the missing variable"

echo
echo "--- 9. the check never writes the file it reads"
# The contract in one assertion. Not a code review: the real versions.env's
# bytes before and after a run that had every reason to want them changed.
before="$(sha256sum "${REAL_ENV}" | cut -d' ' -f1)"
run_case readonly-proof "${REAL_ENV}" "catatonit-moved.json:catatonit"
after="$(sha256sum "${REAL_ENV}" | cut -d' ' -f1)"
if [ "${before}" = "${after}" ]; then
    pass "a run that found a pin behind left versions.env byte-identical (${before:0:12})"
else
    fail "versions.env changed under a check that is only allowed to read it"
fi

echo
if [ "${FAIL_N}" -eq 0 ]; then
    echo "RESULT: PASS (${PASS_N}/${PASS_N} assertions)"
else
    echo "RESULT: FAIL (${FAIL_N} of $((PASS_N + FAIL_N)) assertions failed)"
    exit 1
fi

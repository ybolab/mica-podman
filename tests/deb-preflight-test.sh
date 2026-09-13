#!/usr/bin/env bash
# The versions stamp and the producer's pre-flight, against a fixture out-<arch>
# this test builds and removes: a directory compiled from a superseded
# versions.env must be refused by name, prepare.sh must never compile in
# pre-flight mode, and an absent binary is a warning where a stale set is a
# refusal. Moved here from the assembly's tests/deb-preflight-test.sh with the
# producer it exercises.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p "$REPO_ROOT/tmp"
TMP=$(mktemp -d "$REPO_ROOT/tmp/deb-preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STAMP_SH="$REPO_ROOT/versions-stamp.sh"
PODMAN_PREPARE="$REPO_ROOT/deb/podman/prepare.sh"
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

echo "== the podman versions stamp, and a pre-flight that must not compile =="

# A real host ELF, because prepare.sh checks the architecture of what it
# stages: the fixture satisfies that check honestly rather than by the check
# being weakened for the test. Resolved by PATH and not by `command -v true`,
# which answers `true` -- the shell builtin -- and never a file.
case "$(uname -m)" in
x86_64) FIX_ARCH=amd64 FIX_ELF=x86-64 ;;
aarch64 | arm64) FIX_ARCH=arm64 FIX_ELF=aarch64 ;;
*) FIX_ARCH="" FIX_ELF="" ;;
esac
HOST_ELF=""
if [ -n "${FIX_ELF}" ]; then
    for c in /bin/true /usr/bin/true /bin/ls /usr/bin/ls /bin/cat /usr/bin/cat; do
        [ -f "${c}" ] || continue
        case "$(file -b "${c}" 2>/dev/null)" in
        *"ELF 64-bit"*"${FIX_ELF}"*) HOST_ELF="${c}"; break ;;
        esac
    done
fi
[ -n "${HOST_ELF}" ] || {
    echo "error: no ${FIX_ELF} ELF was found among the standard binaries on this host, so section D has nothing to build its fixture out-${FIX_ARCH} from. Skipping it would leave the stamp guard untested, which is the state that guard exists to end" >&2
    exit 1
}

# A FIXTURE repository root. MICA_DEB_REPO_ROOT is the seam the driver itself
# sets, so the real prepare.sh runs unmodified against a tree this test owns.
FIX="${TMP}/fixture"
FIXP="${FIX}"
OUTDIR="${FIXP}/out-${FIX_ARCH}"
mkdir -p "${FIXP}/deb/podman" "${OUTDIR}"
cp "${REPO_ROOT}/versions.env" "${FIXP}/versions.env"
cp "${STAMP_SH}" "${FIXP}/versions-stamp.sh"
# THE TRIPWIRE. prepare.sh runs this when it decides to compile, and in
# pre-flight mode it must never decide that. A placeholder that fails loudly
# turns "the pre-flight compiled" from a forty-five minute wait into a red line.
cat >"${FIXP}/build.sh" <<'TRIPWIRE'
#!/usr/bin/env bash
echo "TRIPWIRE: the container engine build was invoked" >&2
exit 99
TRIPWIRE
BINARIES=(podman quadlet crun conmon netavark aardvark-dns catatonit)
for b in "${BINARIES[@]}"; do cp "${HOST_ELF}" "${OUTDIR}/${b}"; done

D_RC=0
D_OUT="$(bash "${FIXP}/versions-stamp.sh" --digest 2>&1)" || D_RC=$?
case "${D_OUT}" in
*[!0-9a-f]* | "") D_RC=1 ;;
*) [ "${#D_OUT}" -eq 64 ] || D_RC=1 ;;
esac
if [ "${D_RC}" -eq 0 ]; then
    pass "D1 --digest yields a sha256 over the normalised versions.env"
else
    fail "D1 expected a 64-hex digest; got '${D_OUT}'"
fi

bash "${FIXP}/versions-stamp.sh" --stamp "${OUTDIR}"
D_RC=0
D_OUT="$(bash "${FIXP}/versions-stamp.sh" --check "${OUTDIR}" 2>&1)" || D_RC=$?
if [ "${D_RC}" -eq 0 ]; then
    pass "D2 a directory stamped from the current versions.env passes --check"
else
    fail "D2 expected --check to pass on a freshly stamped directory; got exit ${D_RC}: ${D_OUT}"
fi

# THE DEFECT THE STAMP CLOSES, stated as build.sh states it: a
# stale out/ looks exactly like a fresh one to anything that only checks the
# files are present. Every file below is still present, executable and the
# right architecture; only the pin it was compiled from has moved.
sed -i 's/^CRUN_VERSION=.*/CRUN_VERSION=1.99.9/' "${FIXP}/versions.env"
D_RC=0
D_OUT="$(bash "${FIXP}/versions-stamp.sh" --check "${OUTDIR}" 2>&1)" || D_RC=$?
if [ "${D_RC}" -ne 0 ] &&
    says "${D_OUT}" "was built from a different versions.env" &&
    says "${D_OUT}" "stamped:" && says "${D_OUT}" "current:"; then
    pass "D3 a version bump makes the stamped directory refuse BY NAME, with both digests"
else
    fail "D3 expected the stale-stamp refusal naming both digests; got exit ${D_RC}: ${D_OUT}"
fi

# prepare.sh's REUSE path, through the same mismatch. That is the path which
# packaged the previous engine silently before the stamp existed.
mkdir -p "${TMP}/stage-d"
D_RC=0
D_OUT="$(MICA_DEB_REPO_ROOT="${FIX}" MICA_DEB_ARCH="${FIX_ARCH}" MICA_DEB_PRODUCER=podman \
    MICA_DEB_STAGE="${TMP}/stage-d" bash "${PODMAN_PREPARE}" 2>&1)" || D_RC=$?
if [ "${D_RC}" -ne 0 ] &&
    says "${D_OUT}" "was built from a different versions.env" &&
    ! says "${D_OUT}" "TRIPWIRE"; then
    pass "D4 prepare.sh refuses to reuse a stale out-${FIX_ARCH}, and does not compile instead"
else
    fail "D4 expected prepare.sh to refuse the stale directory without compiling; got exit ${D_RC}: ${D_OUT}"
fi

# Restore the pin and the same reuse succeeds -- the guard is a claim about
# STALENESS, not a refusal of reuse. Without this direction the guard could be
# a bare `exit 1` and every case above would still pass.
sed -i 's/^CRUN_VERSION=.*/CRUN_VERSION=1.29.1/' "${FIXP}/versions.env"
rm -rf "${TMP}/stage-d"
mkdir -p "${TMP}/stage-d"
D_RC=0
D_OUT="$(MICA_DEB_REPO_ROOT="${FIX}" MICA_DEB_ARCH="${FIX_ARCH}" MICA_DEB_PRODUCER=podman \
    MICA_DEB_STAGE="${TMP}/stage-d" bash "${PODMAN_PREPARE}" 2>&1)" || D_RC=$?
staged="$(find "${TMP}/stage-d" -type f | wc -l)"
# Seven binaries and the versions.env they were built from, which rides in
# the payload as /usr/share/mica-podman/versions.env.
EXPECT_STAGED="$((${#BINARIES[@]} + 1))"
if [ "${D_RC}" -eq 0 ] && [ "${staged}" = "${EXPECT_STAGED}" ] && [ -f "${TMP}/stage-d/versions.env" ] && ! says "${D_OUT}" "TRIPWIRE"; then
    pass "D5 restoring the pin lets the same directory be reused, staging ${#BINARIES[@]} binaries and versions.env"
else
    fail "D5 expected reuse to succeed and stage ${EXPECT_STAGED} files including versions.env; got exit ${D_RC}, staged ${staged}: ${D_OUT}"
fi

# An UNSTAMPED directory: what every out-<arch> on every host looked like
# before this guard, and the state in which it must not be trusted.
rm -f "${OUTDIR}/VERSIONS.env"
D_RC=0
D_OUT="$(bash "${FIXP}/versions-stamp.sh" --check "${OUTDIR}" 2>&1)" || D_RC=$?
if [ "${D_RC}" -ne 0 ] && says "${D_OUT}" "carries no VERSIONS.env"; then
    pass "D6 an unstamped directory is refused rather than trusted"
else
    fail "D6 expected the unstamped refusal; got exit ${D_RC}: ${D_OUT}"
fi
bash "${FIXP}/versions-stamp.sh" --stamp "${OUTDIR}"

# PRE-FLIGHT MODE, and the thing it must not do. No MICA_DEB_STAGE is passed,
# because the driver has not made one: no build has started.
D_EX=""
D_MI=""
D_WA=""
run_podman_preflight() {
    D_RC=0
    D_OUT="$(MICA_DEB_PREFLIGHT=1 MICA_DEB_REPO_ROOT="${FIX}" MICA_DEB_ARCH="${FIX_ARCH}" \
        MICA_DEB_PRODUCER=podman bash "${PODMAN_PREPARE}" 2>&1)" || D_RC=$?
    D_EX="$(printf '%s\n' "${D_OUT}" | sed -n 's/^preflight-examined: //p')"
    D_MI="$(printf '%s\n' "${D_OUT}" | sed -n 's/^preflight-missing: //p')"
    D_WA="$(printf '%s\n' "${D_OUT}" | sed -n 's/^preflight-warned: //p')"
}
EXPECT_EX="$((${#BINARIES[@]} + 1))"

run_podman_preflight
if [ "${D_RC}" -eq 0 ] && [ "${D_EX}" = "${EXPECT_EX}" ] && [ "${D_MI}" = 0 ] && [ "${D_WA}" = 0 ] &&
    ! says "${D_OUT}" "TRIPWIRE"; then
    pass "D7 the podman hook answers the pre-flight over ${D_EX} inputs without compiling"
else
    fail "D7 expected exit 0, examined ${EXPECT_EX}, missing 0, warned 0 and no compile; got exit ${D_RC}, examined '${D_EX}', missing '${D_MI}', warned '${D_WA}': ${D_OUT}"
fi

# THE FORTY-FIVE MINUTE CASE, and it is a WARNING rather than a refusal. This
# producer builds its own binaries, so an absent one does not stop the run --
# it costs three quarters of an hour somewhere the operator did not expect, and
# saying so in advance is the whole point. Refusing instead would mean `make
# os-debs` could no longer build a pool on a fresh host, which its own help
# line promises it can.
#
# What the case still requires: exit 0, the cost and the command named, the
# count in the WARNED column and not the missing one, and no compile.
rm -f "${OUTDIR}/crun"
run_podman_preflight
if [ "${D_RC}" -eq 0 ] && [ "${D_EX}" = "${EXPECT_EX}" ] && [ "${D_MI}" = 0 ] && [ "${D_WA}" = 1 ] &&
    says "${D_OUT}" "warning:" && says "${D_OUT}" "make podman" &&
    says "${D_OUT}" "three quarters of an hour" && ! says "${D_OUT}" "TRIPWIRE"; then
    pass "D8 an absent binary WARNS with the cost and the command, does not refuse, and does not compile"
else
    fail "D8 expected exit 0, examined ${EXPECT_EX}, missing 0, warned 1, the cost named and no compile; got exit ${D_RC}, examined '${D_EX}', missing '${D_MI}', warned '${D_WA}': ${D_OUT}"
fi

# THE LINE BETWEEN THE TWO CATEGORIES. Complete but STALE is the case nothing
# in the run can fix -- prepare.sh refuses it -- so it must land in the missing
# column and turn the run red, while the case above stays a warning. Without
# this the two categories could be one, with every case above still passing.
cp "${HOST_ELF}" "${OUTDIR}/crun"
sed -i 's/^CRUN_VERSION=.*/CRUN_VERSION=1.99.9/' "${FIXP}/versions.env"
run_podman_preflight
if [ "${D_RC}" -ne 0 ] && [ "${D_EX}" = "${EXPECT_EX}" ] && [ "${D_MI}" = 1 ] && [ "${D_WA}" = 0 ] &&
    says "${D_OUT}" "was built from a different versions.env" &&
    ! says "${D_OUT}" "TRIPWIRE"; then
    pass "D9 a complete but STALE directory is MISSING, not warned: the run goes red and nothing compiles"
else
    fail "D9 expected exit!=0, examined ${EXPECT_EX}, missing 1, warned 0 and no compile; got exit ${D_RC}, examined '${D_EX}', missing '${D_MI}', warned '${D_WA}': ${D_OUT}"
fi
sed -i 's/^CRUN_VERSION=.*/CRUN_VERSION=1.29.1/' "${FIXP}/versions.env"


echo "RESULT: $PASS_N passed, $FAIL_N failed"
test "$FAIL_N" = 0

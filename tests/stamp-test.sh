#!/usr/bin/env bash
# versions-stamp.sh and the checks tools/package.sh runs before any docker call,
# against a fixture _out/podman/<arch> of host ELF files: a stale, unstamped or
# incomplete directory is refused by name and never packed.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p "$REPO_ROOT/_out"
TMP=$(mktemp -d "$REPO_ROOT/_out/stamp-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

case "$(uname -m)" in
x86_64) ARCH=amd64 ELF=x86-64 ;;
aarch64 | arm64) ARCH=arm64 ELF=aarch64 ;;
*) echo "error: no fixture architecture for $(uname -m)" >&2; exit 1 ;;
esac
HOST_ELF=""
for c in /bin/true /usr/bin/true /bin/ls /usr/bin/ls; do
    case "$(file -b "${c}" 2>/dev/null)" in *"ELF 64-bit"*"${ELF}"*) HOST_ELF="${c}"; break ;; esac
done
[ -n "${HOST_ELF}" ] || { echo "error: no ${ELF} ELF found on this host for the fixture" >&2; exit 1; }

FIX="$TMP/fixture"
OUT="$FIX/_out/podman/$ARCH"
mkdir -p "$FIX/tools" "$OUT" "$TMP/bin"
cp versions.env versions-stamp.sh "$FIX/"
cp tools/package.sh tools/buildx.sh "$FIX/tools/"
BINARIES=(podman quadlet crun conmon netavark aardvark-dns catatonit)
for b in "${BINARIES[@]}"; do cp "$HOST_ELF" "$OUT/$b"; done
# Any docker call is recorded: packing starts only after every check passed.
printf '#!/bin/sh\necho "$@" >>"%s/docker.calls"\nexit 99\n' "$TMP" >"$TMP/bin/docker"
chmod +x "$TMP/bin/docker"

package() {
    RC=0
    rm -f "$TMP/docker.calls"
    OUT_TEXT=$(PATH="$TMP/bin:$PATH" bash "$FIX/tools/package.sh" --arch "$ARCH" 2>&1) || RC=$?
}
stamp() { bash "$FIX/versions-stamp.sh" "$@" 2>&1; }

D="$(stamp --digest)"
if [[ "$D" =~ ^[0-9a-f]{64}$ ]]; then pass "S1 --digest is a sha256 of the lock"; else fail "S1 got '$D'"; fi

stamp --stamp "$OUT" >/dev/null
if stamp --check "$OUT" >/dev/null; then pass "S2 a freshly stamped directory passes --check"; else fail "S2 $(stamp --check "$OUT")"; fi

sed -i 's/^CRUN_VERSION=.*/CRUN_VERSION=1.99.9/' "$FIX/versions.env"
RC=0; T="$(stamp --check "$OUT")" || RC=$?
if [ "$RC" -ne 0 ] && says "$T" "was built from a different versions.env" && says "$T" "stamped:" && says "$T" "current:"; then
    pass "S3 a version bump makes the directory refuse, naming both digests"
else fail "S3 rc=$RC: $T"; fi

package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "was built from a different versions.env" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S4 package.sh refuses a stale directory before any docker call"
else fail "S4 rc=$RC: $OUT_TEXT"; fi

sed -i 's/^CRUN_VERSION=.*/CRUN_VERSION=1.29.1/' "$FIX/versions.env"
package
if [ -e "$TMP/docker.calls" ] && ! says "$OUT_TEXT" "versions.env" && ! says "$OUT_TEXT" "missing"; then
    pass "S5 a current, complete directory passes every check and reaches docker"
else fail "S5 rc=$RC: $OUT_TEXT"; fi

rm -f "$OUT/VERSIONS.env"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "carries no VERSIONS.env" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S6 an unstamped directory is refused"
else fail "S6 rc=$RC: $OUT_TEXT"; fi
stamp --stamp "$OUT" >/dev/null

rm -f "$OUT/crun"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "crun" && says "$OUT_TEXT" "make podman" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S7 a missing binary is refused with the command that builds it"
else fail "S7 rc=$RC: $OUT_TEXT"; fi

echo "text" >"$OUT/crun"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "is not an ${ELF} ELF" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S8 a binary of another architecture is refused"
else fail "S8 rc=$RC: $OUT_TEXT"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]

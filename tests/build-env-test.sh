#!/usr/bin/env bash
# tools/build-env.sh against a fixture release served over file://: the pinned
# SHA256SUMS hash is checked before any other asset is fetched, then every asset
# and the archive top directory; image pins are validated (offline).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p "$REPO_ROOT/_out"
TMP=$(mktemp -d "$REPO_ROOT/_out/build-env-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

V=9.9.9
DIGEST=$(printf 'a%.0s' $(seq 64))
release() { # <dir> [top-dir]
    local dir="$1" top="${2:-mica-build-env-v${V}}"
    mkdir -p "$dir/v${V}" "$TMP/src/$top"
    echo "rules" >"$TMP/src/$top/RULES.md"
    tar -C "$TMP/src" -czf "$dir/v${V}/mica-build-env-v${V}.tar.gz" "$top"
    rm -rf "$TMP/src"
    cat >"$dir/v${V}/images.env" <<EOF
IMAGE_MICA_BUILD_BASE=ghcr.io/ybolab/mica-build-env:base.inputs-0123456789abcdef@sha256:${DIGEST}
IMAGE_MICA_BUILD_C=ghcr.io/ybolab/mica-build-env:c.inputs-0123456789abcdef
EOF
    (cd "$dir/v${V}" && sha256sum "mica-build-env-v${V}.tar.gz" images.env >SHA256SUMS)
}
pin() { # <release-dir> [sha]
    local sha="${2:-$(sha256sum "$1/v${V}/SHA256SUMS" | cut -d' ' -f1)}"
    printf 'MICA_BUILD_ENV_VERSION=%s\nMICA_BUILD_ENV_SHA256SUMS=%s\n' "$V" "$sha" >"$TMP/pin.env"
}
run() { # <release-dir> args...
    RC=0
    OUT=$(MICA_BUILD_ENV_PIN="$TMP/pin.env" MICA_BUILD_ENV_URL="file://$1" MICA_BUILD_ENV_CACHE="$TMP/cache" \
        bash tools/build-env.sh "${@:2}" 2>&1) || RC=$?
}

GOOD="$TMP/good"
release "$GOOD"
pin "$GOOD"
run "$GOOD" fetch
if [ "$RC" -eq 0 ] && [ -f "$TMP/cache/v${V}/mica-build-env-v${V}/RULES.md" ]; then pass "B1 a release matching its pin is fetched and unpacked"; else fail "B1 rc=$RC: $OUT"; fi

run "$GOOD" image IMAGE_MICA_BUILD_BASE
if [ "$RC" -eq 0 ] && [ "$OUT" = "ghcr.io/ybolab/mica-build-env:base.inputs-0123456789abcdef@sha256:${DIGEST}" ]; then pass "B2 image prints the digest pin"; else fail "B2 rc=$RC: $OUT"; fi

run "$GOOD" image IMAGE_MICA_BUILD_C
if [ "$RC" -ne 0 ] && says "$OUT" "not a digest pin"; then pass "B3 a pin without a digest is refused"; else fail "B3 rc=$RC: $OUT"; fi

run "$GOOD" image IMAGE_MICA_BUILD_GO
if [ "$RC" -ne 0 ] && says "$OUT" "IMAGE_MICA_BUILD_GO"; then pass "B4 a key the release does not carry is refused"; else fail "B4 rc=$RC: $OUT"; fi

rm -rf "$TMP/cache"
pin "$GOOD" "$(printf 'b%.0s' $(seq 64))"
run "$GOOD" fetch
if [ "$RC" -ne 0 ] && says "$OUT" "SHA256SUMS of v${V} hashes to" && [ ! -e "$TMP/cache/v${V}/images.env" ]; then
    pass "B5 a SHA256SUMS other than the pinned one is refused before any other asset is used"
else fail "B5 rc=$RC: $OUT"; fi

TAMPERED="$TMP/tampered"
release "$TAMPERED"
pin "$TAMPERED"
echo "IMAGE_MICA_BUILD_RUST=x" >>"$TAMPERED/v${V}/images.env"
rm -rf "$TMP/cache"
run "$TAMPERED" fetch
if [ "$RC" -ne 0 ] && says "$OUT" "images.env" && [ ! -d "$TMP/cache/v${V}" ]; then pass "B6 an asset that fails SHA256SUMS is refused and nothing is kept"; else fail "B6 rc=$RC: $OUT"; fi

TOP="$TMP/top"
release "$TOP" other-top
pin "$TOP"
rm -rf "$TMP/cache"
run "$TOP" fetch
if [ "$RC" -ne 0 ] && says "$OUT" "top directory"; then pass "B7 an archive with another top directory is refused"; else fail "B7 rc=$RC: $OUT"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]

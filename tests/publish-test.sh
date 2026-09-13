#!/usr/bin/env bash
# tools/publish.sh against local registries (the IMAGE_REGISTRY_2 pin of the
# mica-build-env release): one open, one requiring credentials (tests/publish/htpasswd,
# a fixture-only password). Fixture archives in a fixture git checkout. Needs docker.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/publish-test.XXXXXX")
CONTAINERS=()
cleanup() {
    [ "${#CONTAINERS[@]}" -eq 0 ] || docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

REGISTRY_IMAGE="$(bash tools/build-env.sh image IMAGE_REGISTRY_2)"
TOKEN="fixture-token"
start_registry() { # <name> [auth] -> sets HOST
    local name="ai-agent-mica-podman-$1-$$" args=()
    [ "${2-}" != auth ] || args=(-e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=fixture -e REGISTRY_AUTH_HTPASSWD_PATH=/htpasswd)
    if [ -f /.dockerenv ] && docker network inspect traefik >/dev/null 2>&1; then
        docker create --label ai-agent=true --name "$name" --network traefik "${args[@]}" "$REGISTRY_IMAGE" >/dev/null
        HOST="$name:5000"
    else
        docker create --label ai-agent=true --name "$name" -p 127.0.0.1::5000 "${args[@]}" "$REGISTRY_IMAGE" >/dev/null
    fi
    CONTAINERS+=("$name")
    [ "${2-}" != auth ] || docker cp tests/publish/htpasswd "$name:/htpasswd" >/dev/null
    docker start "$name" >/dev/null
    [ -n "${HOST-}" ] && [ "${HOST%%:*}" = "$name" ] || HOST="127.0.0.1:$(docker port "$name" 5000 | head -n1 | sed 's/.*://')"
    for _ in $(seq 1 30); do
        case "$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST/v2/")" in 200 | 401) return 0 ;; esac
        sleep 1
    done
    echo "error: registry $name did not start" >&2
    exit 1
}
HOST=""; start_registry open; OPEN="$HOST"
HOST=""; start_registry auth auth; AUTH="$HOST"

# A fixture checkout of the publisher at one clean commit.
FIX="$TMP/repo"
mkdir -p "$FIX/tools"
cp tools/publish.sh "$FIX/tools/"
printf '_out/\n' >"$FIX/.gitignore"
git -C "$FIX" init -q
git -C "$FIX" remote add origin https://github.com/ybolab/mica-podman.git
git -C "$FIX" -c user.name=fixture -c user.email=fixture@invalid add -A
git -C "$FIX" -c user.name=fixture -c user.email=fixture@invalid commit -qm fixture
COMMIT=$(git -C "$FIX" rev-parse HEAD)
C12=${COMMIT:0:12}
V="5.8.6+git${C12}-1"

deb() { # <arch> [version] [commit] [repo] [payload] [name]
    local arch="$1" version="${2:-$V}" commit="${3:-$COMMIT}" repo="${4:-mica-podman}" payload="${5:-payload}"
    local d="$TMP/pkg-$arch" out="$FIX/_out/debs/$arch"
    rm -rf "$d"
    mkdir -p "$d/DEBIAN" "$d/usr/share/mica-podman" "$out"
    printf '%s\n' "$payload" >"$d/usr/share/mica-podman/fixture"
    printf 'Package: mica-podman\nVersion: %s\nArchitecture: %s\nMaintainer: Mica OS <hi@micaos.dev>\nDescription: fixture\nMica-Source-Repo: %s\nMica-Source-Commit: %s\n' \
        "$version" "$arch" "$repo" "$commit" >"$d/DEBIAN/control"
    find "$d" -exec touch -h -d @1700000000 {} +
    SOURCE_DATE_EPOCH=1700000000 dpkg-deb --build --root-owner-group "$d" "$out/${6:-mica-podman_${version}_${arch}.deb}" >/dev/null
}
reset_debs() { rm -rf "$FIX/_out/debs"; deb amd64; deb arm64; }
publish() { # <host> [token]
    RC=0
    OUT=$(MICA_REGISTRY="$1/ybolab" MICA_REGISTRY_PLAIN_HTTP=1 MICA_REGISTRY_USER=fixture GH_TOKEN="${2:-$TOKEN}" \
        bash "$FIX/tools/publish.sh" 2>&1) || RC=$?
    ! says "$OUT" "${2:-$TOKEN}" || { fail "the token appeared in the output"; }
}
manifest() { # <host> <tag> -> manifest bytes
    curl -s -H 'Accept: application/vnd.oci.image.manifest.v1+json' "http://$1/v2/ybolab/mica-podman/manifests/$2"
}
digest_of() { manifest "$1" "$2" | sha256sum | cut -d' ' -f1; }

reset_debs
publish "$OPEN"
M="$(manifest "$OPEN" "pool.amd64.build-$C12")"
AMD_SHA="$(sha256sum "$FIX/_out/debs/amd64/mica-podman_${V}_amd64.deb" | cut -d' ' -f1)"
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$M" | jq -r '[.artifactType, .config.mediaType, .annotations["org.opencontainers.image.revision"], .annotations["mica.source-repo"], .annotations["mica.source-commit"], .annotations["mica.arch"], .annotations["org.opencontainers.image.source"], (.layers | length), .layers[0].mediaType, .layers[0].digest, .layers[0].annotations["org.opencontainers.image.title"]] | join(" ")')" = \
    "application/vnd.mica.pool application/vnd.oci.empty.v1+json $COMMIT mica-podman $COMMIT amd64 https://github.com/ybolab/mica-podman 1 application/vnd.mica.deb sha256:$AMD_SHA mica-podman_${V}_amd64.deb" ] &&
    [ -n "$(manifest "$OPEN" "pool.arm64.build-$C12" | jq -r '.layers[0].digest')" ] && says "$OUT" "read back anonymously"; then
    pass "P1 both pools are pushed with the identity annotations, one deb layer each, and read back"
else fail "P1 rc=$RC: $OUT | $M"; fi

BEFORE="$(digest_of "$OPEN" "pool.amd64.build-$C12")"
publish "$OPEN"
if [ "$RC" -eq 0 ] && says "$OUT" "exists with these bytes" && [ "$(digest_of "$OPEN" "pool.amd64.build-$C12")" = "$BEFORE" ]; then
    pass "P2 a rerun over identical tags pushes nothing and re-reads them"
else fail "P2 rc=$RC: $OUT"; fi

deb amd64 "$V" "$COMMIT" mica-podman other-payload
publish "$OPEN"
if [ "$RC" -ne 0 ] && says "$OUT" "pool.amd64.build-$C12 exists with other bytes or identity" && [ "$(digest_of "$OPEN" "pool.amd64.build-$C12")" = "$BEFORE" ]; then
    pass "P3 an existing tag holding other bytes is refused and not re-pointed"
else fail "P3 rc=$RC: $OUT"; fi
reset_debs

RIGHT="$(manifest "$OPEN" "pool.arm64.build-$C12")"
WRONG="$(printf '%s' "$RIGHT" | jq -jc '.annotations["mica.source-repo"] = "other"')"
curl -s -o /dev/null -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary "$WRONG" \
    "http://$OPEN/v2/ybolab/mica-podman/manifests/pool.arm64.build-$C12"
publish "$OPEN"
if [ "$RC" -ne 0 ] && says "$OUT" "pool.arm64.build-$C12 exists with other bytes or identity"; then
    pass "P4 an existing tag with the same bytes but another identity is refused"
else fail "P4 rc=$RC: $OUT"; fi

HOST=""; start_registry fresh; FRESH="$HOST"
echo change >>"$FIX/.gitignore"
publish "$FRESH"
if [ "$RC" -ne 0 ] && says "$OUT" "uncommitted changes" && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$FRESH/v2/ybolab/mica-podman/tags/list")" = 404 ]; then
    pass "P5 a dirty checkout is refused before any registry write"
else fail "P5 rc=$RC: $OUT"; fi
git -C "$FIX" checkout -q -- .gitignore

refused() { # <label> <expected message>
    publish "$FRESH"
    if [ "$RC" -ne 0 ] && says "$OUT" "$2" && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$FRESH/v2/ybolab/mica-podman/tags/list")" = 404 ]; then
        pass "$1"
    else fail "$1: rc=$RC: $OUT"; fi
    reset_debs
}
rm -rf "$FIX/_out/debs"; deb amd64 "5.8.6+git${C12}.dirty-1"; deb arm64
refused "P6 a .dirty archive is refused" "is not <upstream>+git${C12}-1"
rm -rf "$FIX/_out/debs/arm64"; deb arm64 "5.8.6+git0123456789ab-1" 0123456789abcdef0123456789abcdef01234567
refused "P7 an archive of another commit (mixed stamps) is refused" "Mica-Source-Commit 0123456789abcdef0123456789abcdef01234567"
rm -rf "$FIX/_out/debs/amd64"; deb amd64 "$V" "$COMMIT" mica-podman payload renamed.deb
refused "P8 an archive not titled Package_Version_Architecture is refused" "renamed.deb"
deb amd64 "$V" "$COMMIT" mica-podman payload extra_amd64.deb
refused "P9 a pool with more than the one expected archive is refused" "holds 2 archives"
rm -rf "$FIX/_out/debs/arm64"; deb arm64 "$V" "$COMMIT" other-repo
refused "P10 an archive of another repository is refused" "Mica-Source-Repo other-repo"

# The fixture registry, not the publisher, restores the arm64 tag; then the
# stored bytes of a published deb are corrupted and read-back must notice.
curl -s -o /dev/null -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary "$RIGHT" \
    "http://$OPEN/v2/ybolab/mica-podman/manifests/pool.arm64.build-$C12"
docker exec "${CONTAINERS[0]}" sh -c "printf X | dd of=/var/lib/registry/docker/registry/v2/blobs/sha256/${AMD_SHA:0:2}/${AMD_SHA}/data bs=1 count=1 conv=notrunc 2>/dev/null"
publish "$OPEN"
if [ "$RC" -ne 0 ] && says "$OUT" "serves"; then pass "P11 corrupt bytes on read-back are refused"; else fail "P11 rc=$RC: $OUT"; fi

publish "$AUTH"
if [ "$RC" -ne 0 ] && says "$OUT" "cannot be read anonymously" && says "$OUT" "https://github.com/orgs/ybolab/packages/container/package/mica-podman" &&
    [ "$(curl -s -o /dev/null -w '%{http_code}' -u "fixture:$TOKEN" -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        "http://$AUTH/v2/ybolab/mica-podman/manifests/pool.arm64.build-$C12")" = 200 ]; then
    pass "P12 a private package is refused after both uploads, with the settings URL"
else fail "P12 rc=$RC: $OUT"; fi

publish "$AUTH" wrong-token
if [ "$RC" -ne 0 ] && says "$OUT" "401"; then pass "P13 refused credentials report their status and are not printed"; else fail "P13 rc=$RC: $OUT"; fi

RC=0
OUT=$(MICA_REGISTRY="$OPEN/ybolab" MICA_REGISTRY_PLAIN_HTTP=1 GH_TOKEN="" bash "$FIX/tools/publish.sh" 2>&1) || RC=$?
if [ "$RC" -ne 0 ] && says "$OUT" "GH_TOKEN and MICA_REGISTRY_USER must be set"; then pass "P14 no credential is refused by name"; else fail "P14 rc=$RC: $OUT"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]

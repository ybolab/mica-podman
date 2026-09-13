#!/usr/bin/env bash
# tools/release.sh against a stub gh (a release store in a directory, served
# over file://) and a bare git remote for the tags. Offline.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/release-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

STORE="$TMP/store"
BARE="$TMP/remote.git"
mkdir -p "$STORE/.meta" "$TMP/bin"
export STORE BARE
git init -q --bare "$BARE"

# The stub: release view | create, recording each call.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STORE/calls"
[ "$1" = release ] || exit 2
cmd="$2" tag="$3"
shift 3
target="" files=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    -R | --json | --title | --notes) shift 2 ;;
    --target) target="$2"; shift 2 ;;
    *) files+=("$1"); shift ;;
    esac
done
meta="$STORE/.meta/$tag.json"
case "$cmd" in
view)
    [ -f "$meta" ] || { echo "release not found" >&2; exit 1; }
    cat "$meta"
    ;;
create)
    [ ! -f "$meta" ] || { echo "a release with the same tag name already exists" >&2; exit 1; }
    mkdir -p "$STORE/$tag"
    assets="[]"
    for f in "${files[@]}"; do
        n="$(basename "$f" | tr '+' '.')"
        cp "$f" "$STORE/$tag/$n"
        assets="$(jq -c --arg n "$n" --argjson s "$(stat -c %s "$f")" --arg d "sha256:$(sha256sum "$f" | cut -d' ' -f1)" '. + [{name: $n, size: $s, digest: $d}]' <<<"$assets")"
    done
    jq -n --arg t "$tag" --arg c "$target" --argjson a "$assets" '{tagName: $t, isDraft: false, targetCommitish: $c, assets: $a}' >"$meta"
    git -C "$BARE" tag "$tag" "$target"
    ;;
*) exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

FIX="$TMP/repo"
mkdir -p "$FIX/tools"
cp tools/release.sh "$FIX/tools/"
printf '_out/\n' >"$FIX/.gitignore"
git -C "$FIX" init -q
git -C "$FIX" remote add origin https://github.com/ybolab/mica-podman.git
git -C "$FIX" -c user.name=f -c user.email=f@invalid add -A
git -C "$FIX" -c user.name=f -c user.email=f@invalid commit -qm one
OTHER=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" -c user.name=f -c user.email=f@invalid commit -qm two --allow-empty
COMMIT=$(git -C "$FIX" rev-parse HEAD)
git -C "$FIX" push -q "$BARE" HEAD:refs/heads/main
C12=${COMMIT:0:12}
TAG="build-$C12"
V="5.8.6+git${C12}-1"

deb() { # <arch> [version] [commit] [payload] [name]
    local arch="$1" version="${2:-$V}" commit="${3:-$COMMIT}" payload="${4:-payload}"
    local d="$TMP/pkg-$arch" out="$FIX/_out/debs/$arch"
    rm -rf "$d"
    mkdir -p "$d/DEBIAN" "$d/usr/share/mica-podman" "$out"
    printf '%s\n' "$payload" >"$d/usr/share/mica-podman/fixture"
    printf 'Package: mica-podman\nVersion: %s\nArchitecture: %s\nMaintainer: Mica OS <hi@micaos.dev>\nDescription: fixture\nMica-Source-Repo: mica-podman\nMica-Source-Commit: %s\n' \
        "$version" "$arch" "$commit" >"$d/DEBIAN/control"
    find "$d" -exec touch -h -d @1700000000 {} +
    SOURCE_DATE_EPOCH=1700000000 dpkg-deb --build --root-owner-group "$d" "$out/${5:-mica-podman_${version}_${arch}.deb}" >/dev/null
}
reset_debs() { rm -rf "$FIX/_out/debs"; deb amd64; deb arm64; }
release() { # [token]
    RC=0
    rm -f "$STORE/calls"
    OUT=$(PATH="$TMP/bin:$PATH" GH_TOKEN="${1-fixture-token}" \
        MICA_RELEASE_DOWNLOAD="file://$STORE" MICA_RELEASE_GIT="$BARE" \
        bash "$FIX/tools/release.sh" 2>&1) || RC=$?
    ! says "$OUT" "fixture-token" || fail "the token appeared in the output"
}
calls() { cat "$STORE/calls" 2>/dev/null || true; }
A64="mica-podman_5.8.6.git${C12}-1_amd64.deb"

reset_debs
release
if [ "$RC" -eq 0 ] && says "$(calls)" "create $TAG" && says "$(calls)" "--target $COMMIT" &&
    [ "$(ls "$STORE/$TAG" | LC_ALL=C sort | tr '\n' ' ')" = "SHA256SUMS $A64 mica-podman_5.8.6.git${C12}-1_arm64.deb " ] &&
    (cd "$STORE/$TAG" && sha256sum --quiet -c SHA256SUMS) && cmp -s "$STORE/$TAG/$A64" "$FIX/_out/debs/amd64/mica-podman_${V}_amd64.deb" &&
    [ "$(git -C "$BARE" rev-parse "$TAG^{commit}")" = "$COMMIT" ] && says "$OUT" "downloaded anonymously"; then
    pass "R1 a new release carries both debs and SHA256SUMS at the commit and downloads back"
else fail "R1 rc=$RC: $OUT"; fi

release
if [ "$RC" -eq 0 ] && ! says "$(calls)" "create" && says "$OUT" "exists with these assets"; then
    pass "R2 a rerun over an identical release uploads nothing and re-downloads"
else fail "R2 rc=$RC: $OUT"; fi

deb amd64 "$V" "$COMMIT" other
release
if [ "$RC" -ne 0 ] && says "$OUT" "$TAG exists with other assets" && ! says "$(calls)" "create"; then
    pass "R3 an existing release with other bytes is refused, not replaced"
else fail "R3 rc=$RC: $OUT"; fi
reset_debs

cp "$STORE/.meta/$TAG.json" "$TMP/meta.bak"
jq '.assets += [{name: "extra", size: 1, digest: "sha256:00"}]' "$TMP/meta.bak" >"$STORE/.meta/$TAG.json"
release
if [ "$RC" -ne 0 ] && says "$OUT" "$TAG exists with other assets"; then pass "R4 an existing release with an extra asset is refused"; else fail "R4 rc=$RC: $OUT"; fi

jq --arg c "$OTHER" '.targetCommitish = $c' "$TMP/meta.bak" >"$STORE/.meta/$TAG.json"
release
if [ "$RC" -ne 0 ] && says "$OUT" "targets $OTHER"; then pass "R5 an existing release of another commit is refused"; else fail "R5 rc=$RC: $OUT"; fi
cp "$TMP/meta.bak" "$STORE/.meta/$TAG.json"

git -C "$BARE" tag -f "$TAG" "$OTHER" >/dev/null
release
if [ "$RC" -ne 0 ] && says "$OUT" "tag $TAG is $OTHER"; then pass "R6 a tag on another commit is refused"; else fail "R6 rc=$RC: $OUT"; fi
git -C "$BARE" tag -f "$TAG" "$COMMIT" >/dev/null

jq '.isDraft = true' "$TMP/meta.bak" >"$STORE/.meta/$TAG.json"
release
if [ "$RC" -ne 0 ] && says "$OUT" "draft"; then pass "R7 an unpublished draft is refused"; else fail "R7 rc=$RC: $OUT"; fi
cp "$TMP/meta.bak" "$STORE/.meta/$TAG.json"

cp "$STORE/$TAG/$A64" "$TMP/a64.bak"
printf X | dd of="$STORE/$TAG/$A64" bs=1 count=1 conv=notrunc 2>/dev/null
release
if [ "$RC" -ne 0 ] && says "$OUT" "downloads with other bytes"; then pass "R8 a download with corrupt bytes is refused"; else fail "R8 rc=$RC: $OUT"; fi
cp "$TMP/a64.bak" "$STORE/$TAG/$A64"

refused() { # <label> <message>
    release
    if [ "$RC" -ne 0 ] && says "$OUT" "$2" && ! says "$(calls)" "release"; then pass "$1"; else fail "$1: rc=$RC: $OUT"; fi
    reset_debs
}
echo change >>"$FIX/.gitignore"
refused "R9 a dirty checkout is refused before any gh call" "uncommitted changes"
git -C "$FIX" checkout -q -- .gitignore
rm -rf "$FIX/_out/debs"; deb amd64 "5.8.6+git${C12}.dirty-1"; deb arm64
refused "R10 a .dirty archive is refused" "is not <upstream>+git${C12}-1"
rm -rf "$FIX/_out/debs/arm64"; deb arm64 "5.8.6+git${OTHER:0:12}-1" "$OTHER"
refused "R11 an archive of another commit is refused" "Mica-Source-Commit $OTHER"
deb amd64 "$V" "$COMMIT" payload extra_amd64.deb
refused "R12 an extra archive is refused" "holds 2 archives"
release ""
if [ "$RC" -ne 0 ] && says "$OUT" "GH_TOKEN must be set" && ! says "$(calls)" "release"; then pass "R13 no credential is refused by name"; else fail "R13 rc=$RC: $OUT"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]

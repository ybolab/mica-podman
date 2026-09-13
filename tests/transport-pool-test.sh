#!/usr/bin/env bash
# tools/transport-pool.sh refuses before any registry access: malformed
# inputs, a revision outside HEAD's history, archive bytes other than the
# pinned digest, a control identity other than the revision's, and a release
# missing an architecture. `gh` is a stub serving fixture archives and no
# token is set, so nothing here can write to a registry (offline; needs the
# substrate, make deps).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p "$REPO_ROOT/tmp"
TMP=$(mktemp -d "$REPO_ROOT/tmp/transport-pool.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

[ -f build-env/deb/control-fields.py ] || { echo "error: build-env/ is empty; run make deps" >&2; exit 1; }

echo "== transport-pool.sh: refusals before any registry access =="

REV=$(git rev-parse HEAD)
C12=${REV:0:12}

# A Debian archive with a control file only: what control-fields.py reads.
mkdeb() { # <out> <package> <version> <arch> <source-repo> <source-commit>
    python3 - "$@" <<'PY'
import io, sys, tarfile
out, pkg, ver, arch, repo, commit = sys.argv[1:]
control = f"Package: {pkg}\nVersion: {ver}\nArchitecture: {arch}\nMica-Source-Repo: {repo}\nMica-Source-Commit: {commit}\n".encode()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w:gz') as tar:
    info = tarfile.TarInfo('./control'); info.size = len(control)
    tar.addfile(info, io.BytesIO(control))
members = [(b'debian-binary', b'2.0\n'), (b'control.tar.gz', buf.getvalue())]
with open(out, 'wb') as f:
    f.write(b'!<arch>\n')
    for name, body in members:
        f.write(name.ljust(16) + b'0'.ljust(12) + b'0'.ljust(6) + b'0'.ljust(6) + b'100644'.ljust(8) + str(len(body)).encode().ljust(10) + b'`\n')
        f.write(body + (b'\n' if len(body) % 2 else b''))
PY
}

# The stub gh copies $FIXTURE_RELEASE/*.deb into the -D directory.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
dir=""
while [ "$#" -gt 0 ]; do case "$1" in -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$dir" ] || exit 2
mkdir -p "$dir"
cp "$FIXTURE_RELEASE"/*.deb "$dir"/
STUB
chmod +x "$TMP/bin/gh"

run() { # <release-dir> args... -> sets OUT, RC
    RC=0
    OUT=$(GH_TOKEN='' MICA_RELEASE_NO_GH=1 FIXTURE_RELEASE="$1" PATH="$TMP/bin:$PATH" bash tools/transport-pool.sh "${@:2}" 2>&1) || RC=$?
}
sha() { sha256sum "$1" | cut -d' ' -f1; }

GOOD="$TMP/good"
mkdir -p "$GOOD"
mkdeb "$GOOD/mica-podman_5.8.6.git${C12}-1_amd64.deb" mica-podman "5.8.6+git${C12}-1" amd64 mica-podman "$REV"
mkdeb "$GOOD/mica-podman_5.8.6.git${C12}-1_arm64.deb" mica-podman "5.8.6+git${C12}-1" arm64 mica-podman "$REV"
SHA_AMD64=$(sha "$GOOD/mica-podman_5.8.6.git${C12}-1_amd64.deb")
SHA_ARM64=$(sha "$GOOD/mica-podman_5.8.6.git${C12}-1_arm64.deb")
worktrees_before=$(git worktree list | wc -l)

run "$GOOD" --revision "${C12}" --expect-amd64 "$SHA_AMD64" --expect-arm64 "$SHA_ARM64"
if [ "$RC" -ne 0 ] && says "$OUT" "full 40-hex commit"; then pass "T1 an abbreviated revision is refused"; else fail "T1 rc=$RC: $OUT"; fi

run "$GOOD" --revision "$REV" --expect-amd64 "$SHA_AMD64"
if [ "$RC" -ne 0 ] && says "$OUT" "--expect-arm64 takes"; then pass "T2 a missing architecture digest is refused"; else fail "T2 rc=$RC: $OUT"; fi

run "$GOOD" --revision fedcba9876543210fedcba9876543210fedcba98 --expect-amd64 "$SHA_AMD64" --expect-arm64 "$SHA_ARM64"
if [ "$RC" -ne 0 ] && says "$OUT" "not a commit in the history of HEAD"; then pass "T3 a revision outside HEAD's history is refused"; else fail "T3 rc=$RC: $OUT"; fi

run "$GOOD" --revision "$REV" --expect-amd64 "$SHA_ARM64" --expect-arm64 "$SHA_ARM64"
if [ "$RC" -ne 0 ] && says "$OUT" "hashes to ${SHA_AMD64}, and consumers pin ${SHA_ARM64}; nothing was published"; then pass "T4 bytes other than the pinned digest are refused, naming both"; else fail "T4 rc=$RC: $OUT"; fi

OTHER="$TMP/other-commit"
mkdir -p "$OTHER"
cp "$GOOD/mica-podman_5.8.6.git${C12}-1_amd64.deb" "$OTHER/"
ELSEWHERE=0123456789abcdef0123456789abcdef01234567
mkdeb "$OTHER/mica-podman_5.8.6.git${C12}-1_arm64.deb" mica-podman "5.8.6+git${C12}-1" arm64 mica-podman "$ELSEWHERE"
run "$OTHER" --revision "$REV" --expect-amd64 "$SHA_AMD64" --expect-arm64 "$(sha "$OTHER/mica-podman_5.8.6.git${C12}-1_arm64.deb")"
if [ "$RC" -ne 0 ] && says "$OUT" "Mica-Source-Commit '${ELSEWHERE}'" && says "$OUT" "nothing was published"; then pass "T5 an archive of another commit is refused even at its own digest"; else fail "T5 rc=$RC: $OUT"; fi

ONE="$TMP/one-arch"
mkdir -p "$ONE"
cp "$GOOD/mica-podman_5.8.6.git${C12}-1_amd64.deb" "$ONE/"
run "$ONE" --revision "$REV" --expect-amd64 "$SHA_AMD64" --expect-arm64 "$SHA_ARM64"
if [ "$RC" -ne 0 ] && says "$OUT" "carries 0 arm64 archive(s)"; then pass "T6 a release missing an architecture is refused"; else fail "T6 rc=$RC: $OUT"; fi

if [ "$(git worktree list | wc -l)" -eq "$worktrees_before" ]; then pass "T7 no refusal left a worktree behind"; else fail "T7 git worktree list grew: $(git worktree list)"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]

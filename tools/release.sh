#!/usr/bin/env bash
# Release _out/debs/{amd64,arm64} of a clean HEAD on main as the GitHub Release
# <YYYYMMDD-HHMM> (UTC, now), tagged at that commit.
#
#   GH_TOKEN=<token with contents:write> bash tools/release.sh
#
# Run by the manual release workflow. Assets: mica-podman_<version>_<arch>.deb
# with `+` written `.` (GitHub's asset naming) and SHA256SUMS over both. Every
# archive is checked before any gh call. Nothing is written unless the commit is
# on main, no release or tag has the name, the name is after the newest release,
# and no release already carries these archives; an existing release is never
# changed. The tag and every asset are then read back with no credential.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE=mica-podman
ARCHES=(amd64 arm64)
die() { echo "release.sh: error: $*" >&2; exit 1; }
for t in gh git curl jq sha256sum dpkg-deb; do
    command -v "${t}" >/dev/null 2>&1 || die "${t} is required and not on PATH"
done

TAG="${MICA_RELEASE_TAG:-$(date -u +%Y%m%d-%H%M)}"
[[ "${TAG}" =~ ^[0-9]{8}-[0-9]{4}$ ]] || die "the tag '${TAG}' is not YYYYMMDD-HHMM"

cd "${REPO_ROOT}"
[ -z "$(git status --porcelain)" ] || die "the checkout has uncommitted changes; only a clean HEAD is released"
COMMIT="$(git rev-parse HEAD)"
C12="${COMMIT:0:12}"
ORIGIN="$(git remote get-url origin)"
[[ "${ORIGIN}" =~ github\.com[:/]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]] || die "origin ${ORIGIN} is not a GitHub repository"
SLUG="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
REPOSITORY="${SLUG#*/}"
DOWNLOAD="${MICA_RELEASE_DOWNLOAD:-https://github.com/${SLUG}/releases/download}"
GIT_URL="${MICA_RELEASE_GIT:-https://github.com/${SLUG}.git}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/assets" "${WORK}/download"

VERSION=""
for arch in "${ARCHES[@]}"; do
    dir="_out/debs/${arch}"
    mapfile -t debs < <(find "${dir}" -maxdepth 1 -type f -name '*.deb' 2>/dev/null | LC_ALL=C sort)
    [ "${#debs[@]}" -eq 1 ] || die "${dir} holds ${#debs[@]} archives; exactly one ${PACKAGE} archive is released per architecture"
    deb="${debs[0]}"
    field() { dpkg-deb --field "${deb}" "$1"; }
    [ "$(field Package)" = "${PACKAGE}" ] || die "${deb} is Package $(field Package), not ${PACKAGE}"
    [ "$(field Architecture)" = "${arch}" ] || die "${deb} is Architecture $(field Architecture), not ${arch}"
    [ "$(field Mica-Source-Repo)" = "${REPOSITORY}" ] || die "${deb} carries Mica-Source-Repo $(field Mica-Source-Repo), not ${REPOSITORY}"
    [ "$(field Mica-Source-Commit)" = "${COMMIT}" ] || die "${deb} carries Mica-Source-Commit $(field Mica-Source-Commit), not HEAD ${COMMIT}"
    v="$(field Version)"
    [[ "${v}" =~ ^[0-9][0-9.]*\+git${C12}-1$ ]] || die "${deb} Version ${v} is not <upstream>+git${C12}-1"
    [ -z "${VERSION}" ] || [ "${v}" = "${VERSION}" ] || die "${deb} Version ${v} differs from ${VERSION}; one stamp per release"
    VERSION="${v}"
    [ "$(basename "${deb}")" = "${PACKAGE}_${v}_${arch}.deb" ] || die "${deb} is not named ${PACKAGE}_${v}_${arch}.deb"
    cp "${deb}" "${WORK}/assets/${PACKAGE}_${v//+/.}_${arch}.deb"
done
(cd "${WORK}/assets" && sha256sum -- *.deb >SHA256SUMS)

[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set; releasing is CI's, with its own token"
git merge-base --is-ancestor "${COMMIT}" origin/main 2>/dev/null || die "${COMMIT} is not on origin/main; only a commit of main is released"

gh api --paginate --slurp "repos/${SLUG}/releases" >"${WORK}/releases.json" || die "listing the releases of ${SLUG} failed"
jq 'add // []' "${WORK}/releases.json" >"${WORK}/all.json"
[ "$(jq --arg t "${TAG}" '[.[] | select(.tag_name == $t)] | length' "${WORK}/all.json")" -eq 0 ] ||
    die "release ${TAG} already exists; a release is never changed"
[ -z "$(git ls-remote --tags "${GIT_URL}" "refs/tags/${TAG}" 2>/dev/null)" ] || die "tag ${TAG} already exists at ${GIT_URL}"
newest="$(jq -r '.[].tag_name' "${WORK}/all.json" | grep -E '^[0-9]{8}-[0-9]{4}$' | LC_ALL=C sort | tail -n1 || true)"
[ -z "${newest}" ] || [[ "${TAG}" > "${newest}" ]] || die "${TAG} is not after the newest release ${newest}"
for f in "${WORK}/assets/"*.deb; do
    released="$(jq -r --arg n "$(basename "${f}")" '[.[] | select(any(.assets[]; .name == $n)) | .tag_name] | join(" ")' "${WORK}/all.json")"
    [ -z "${released}" ] || die "$(basename "${f}") is already released as ${released}; ${COMMIT} is not released twice"
done

gh release create "${TAG}" -R "${SLUG}" --target "${COMMIT}" --title "${TAG}" \
    --notes "mica-podman ${VERSION} (amd64, arm64) built from ${SLUG}@${COMMIT}. Verify with SHA256SUMS." \
    "${WORK}/assets/SHA256SUMS" "${WORK}/assets/"*.deb >/dev/null
echo "release.sh: created ${SLUG} ${TAG} at ${COMMIT}"

# Anonymous: the tag, then every asset through the download URL.
tagged=""
for _ in 1 2 3 4 5; do
    tagged="$(git ls-remote --tags "${GIT_URL}" 2>/dev/null | awk -v t="refs/tags/${TAG}" '$2 == t || $2 == t "^{}" { sha = $1 } END { print sha }')"
    [ -z "${tagged}" ] || break
    sleep 3
done
[ "${tagged}" = "${COMMIT}" ] || die "tag ${TAG} is ${tagged:-absent} at ${GIT_URL}, not ${COMMIT}"
for f in "${WORK}/assets/"*; do
    n="$(basename "${f}")"
    curl -fsSL --retry 5 --retry-delay 5 --max-time 600 -o "${WORK}/download/${n}" "${DOWNLOAD}/${TAG}/${n}" ||
        die "${DOWNLOAD}/${TAG}/${n} cannot be downloaded anonymously"
    cmp -s "${WORK}/download/${n}" "${f}" || die "${DOWNLOAD}/${TAG}/${n} downloads with other bytes"
done
(cd "${WORK}/download" && sha256sum --quiet -c SHA256SUMS) || die "the downloaded assets of ${TAG} do not match SHA256SUMS"
echo "release.sh: ${DOWNLOAD}/${TAG}/ downloaded anonymously, tag ${TAG} at ${COMMIT}"
echo "release.sh: SHA256SUMS sha256 $(sha256sum "${WORK}/assets/SHA256SUMS" | cut -d' ' -f1)"
sed 's/^/release.sh:   /' "${WORK}/assets/SHA256SUMS"

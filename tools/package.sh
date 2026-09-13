#!/usr/bin/env bash
# Pack _out/podman/<arch> as mica-podman_<PODMAN_VERSION>+git<commit12>[.dirty]-1_<arch>.deb.
#
#   bash tools/package.sh --arch <amd64|arm64> [--out <dir>] [--no-cache]
#
# Writes <dir>/<arch>/ (default _out/debs). The binaries must be complete, of
# the target architecture and stamped by the current versions.env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "package.sh: error: $*" >&2; exit 1; }

ARCH="" OUT_ROOT="${REPO_ROOT}/_out/debs" NO_CACHE=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --arch) ARCH="${2-}"; shift 2 ;;
    --out) OUT_ROOT="${2-}"; shift 2 ;;
    --no-cache) NO_CACHE=(--no-cache); shift ;;
    *) die "usage: bash tools/package.sh --arch <amd64|arm64> [--out <dir>] [--no-cache]" ;;
    esac
done
case "${ARCH}" in
amd64) ELF_ARCH=x86-64 ;;
arm64) ELF_ARCH=aarch64 ;;
*) die "--arch must be amd64 or arm64" ;;
esac

BIN="${REPO_ROOT}/_out/podman/${ARCH}"
BINARIES=(podman quadlet crun conmon netavark aardvark-dns catatonit)
missing=""
for b in "${BINARIES[@]}"; do
    [ -f "${BIN}/${b}" ] || missing="${missing} ${b}"
done
[ -z "${missing}" ] || die "${BIN} is missing${missing}; run MICA_ARCH=${ARCH} make podman"
bash "${REPO_ROOT}/versions-stamp.sh" --check "${BIN}"
for b in "${BINARIES[@]}"; do
    case "$(file -b "${BIN}/${b}")" in
    *"ELF 64-bit"*"${ELF_ARCH}"*) ;;
    *) die "${BIN}/${b} is not an ${ELF_ARCH} ELF; run MICA_ARCH=${ARCH} make podman" ;;
    esac
done

# shellcheck disable=SC1091
. "${REPO_ROOT}/tools/buildx.sh"
buildx_builder "${ARCH}"

COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
DIRTY=""
[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ] || DIRTY=".dirty"
PODMAN_VERSION="$(sed -n 's/^PODMAN_VERSION=v\{0,1\}//p' "${REPO_ROOT}/versions.env")"
[[ "${PODMAN_VERSION}" =~ ^[0-9][0-9.]*$ ]] || die "versions.env PODMAN_VERSION '${PODMAN_VERSION}' is not a version"
VERSION="${PODMAN_VERSION}+git${COMMIT:0:12}${DIRTY}-1"
EPOCH="$(git -C "${REPO_ROOT}" show -s --format=%ct HEAD)"
ORIGIN="$(git -C "${REPO_ROOT}" remote get-url origin)"
SOURCE_REPO="$(basename "${ORIGIN%/}" .git)"
BASE="$(bash "${REPO_ROOT}/tools/build-env.sh" image IMAGE_MICA_BUILD_BASE)"

STAGE="${REPO_ROOT}/_out/stage/${ARCH}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp "${BINARIES[@]/#/${BIN}/}" "${REPO_ROOT}/versions.env" "${STAGE}/"

DEST="${OUT_ROOT}/${ARCH}"
rm -rf "${DEST}"
docker buildx build --builder "${BUILDER}" --platform "linux/${ARCH}" ${NO_CACHE[@]+"${NO_CACHE[@]}"} \
    --build-arg "MICA_BUILD_BASE=${BASE}" \
    --build-arg "MICA_DEB_VERSION=${VERSION}" \
    --build-arg "MICA_DEB_ARCH=${ARCH}" \
    --build-arg "SOURCE_DATE_EPOCH=${EPOCH}" \
    --build-arg "MICA_DEB_SOURCE_REPO=${SOURCE_REPO}" \
    --build-arg "MICA_DEB_SOURCE_COMMIT=${COMMIT}" \
    --build-context "overlay=${REPO_ROOT}/overlay" \
    --build-context "bin=${STAGE}" \
    -f "${REPO_ROOT}/deb/Dockerfile" \
    -o "type=local,dest=${DEST}" \
    "${REPO_ROOT}/deb"

want="mica-podman_${VERSION}_${ARCH}.deb"
[ "$(ls -A "${DEST}")" = "${want}" ] || die "${DEST} holds '$(ls -A "${DEST}" | tr '\n' ' ')', expected ${want}"
echo "package.sh: ${DEST#"${REPO_ROOT}"/}/${want} on ${BASE}"

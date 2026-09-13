#!/usr/bin/env bash
# Build the seven engine binaries for MICA_ARCH (arm64 by default) into
# _out/podman/<arch>/, on the images the pinned mica-build-env release names.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MICA_ARCH="${MICA_ARCH:-arm64}"
case "${MICA_ARCH}" in
arm64) ELF_ARCH=aarch64 ;;
amd64) ELF_ARCH=x86-64 ;;
*) echo "error: MICA_ARCH is '${MICA_ARCH}'; it must be arm64 or amd64" >&2; exit 1 ;;
esac
OUT="${HERE}/_out/podman/${MICA_ARCH}"

# shellcheck disable=SC1091
. "${HERE}/tools/buildx.sh"
buildx_builder "${MICA_ARCH}"

IMAGE_ARGS=()
for image in BASE C GO RUST; do
    ref="$(bash "${HERE}/tools/build-env.sh" image "IMAGE_MICA_BUILD_${image}")"
    IMAGE_ARGS+=(--build-arg "MICA_BUILD_${image}=${ref}")
done

# The src stage copies versions.lock, so comment edits keep the cache.
bash "${HERE}/versions-stamp.sh" --lock >"${HERE}/versions.lock"

rm -rf "${OUT}"
mkdir -p "${OUT}"

docker buildx build --builder "${BUILDER}" \
    --platform "linux/${MICA_ARCH}" \
    "${IMAGE_ARGS[@]}" \
    --build-arg "ELF_ARCH=${ELF_ARCH}" \
    -f "${HERE}/Dockerfile" \
    -o "type=local,dest=${OUT}" \
    "${HERE}"

missing=""
for b in podman quadlet crun conmon catatonit netavark aardvark-dns; do
    [ -f "${OUT}/${b}" ] || missing="${missing} ${b}"
done
[ -z "${missing}" ] || {
    echo "error: the build reported success but these binaries are not in ${OUT}:${missing}" >&2
    exit 1
}

bash "${HERE}/versions-stamp.sh" --stamp "${OUT}"

echo "=== ${OUT} ==="
for b in podman quadlet crun conmon catatonit netavark aardvark-dns; do
    printf '  %-14s %8s KiB  %s\n' "${b}" "$(($(stat -c%s "${OUT}/${b}") / 1024))" "$(file -b "${OUT}/${b}" | cut -c1-46)"
done

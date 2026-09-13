#!/usr/bin/env bash
# The mica-build-env release this repository builds with (build-env.env),
# verified as its RULES.md section 1 requires.
#
#   bash tools/build-env.sh fetch          assets into _out/build-env/v<version>/, verified
#   bash tools/build-env.sh image <KEY>    one IMAGE_* digest pin from that images.env
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="${MICA_BUILD_ENV_PIN:-${REPO_ROOT}/build-env.env}"
URL="${MICA_BUILD_ENV_URL:-https://github.com/ybolab/mica-build-env/releases/download}"
CACHE="${MICA_BUILD_ENV_CACHE:-${REPO_ROOT}/_out/build-env}"

die() { echo "build-env.sh: error: $*" >&2; exit 1; }

pin_value() { sed -n "s/^$1=//p" "${PIN}"; }
[ -f "${PIN}" ] || die "${PIN} does not exist"
VERSION="$(pin_value MICA_BUILD_ENV_VERSION)"
SUMS_SHA="$(pin_value MICA_BUILD_ENV_SHA256SUMS)"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "${PIN}: MICA_BUILD_ENV_VERSION '${VERSION}' is not X.Y.Z"
[[ "${SUMS_SHA}" =~ ^[0-9a-f]{64}$ ]] || die "${PIN}: MICA_BUILD_ENV_SHA256SUMS is not 64 hex"
case "${URL}" in https://* | file://*) ;; *) die "MICA_BUILD_ENV_URL '${URL}' is not https" ;; esac

TAG="v${VERSION}"
ARCHIVE="mica-build-env-${TAG}.tar.gz"
DIR="${CACHE}/${TAG}"

# Verifies <dir> in place: SHA256SUMS against the pin, then the assets it lists.
verify() {
    local dir="$1" got
    got="$(sha256sum "${dir}/SHA256SUMS" | cut -d' ' -f1)"
    [ "${got}" = "${SUMS_SHA}" ] || die "SHA256SUMS of ${TAG} hashes to ${got}; build-env.env pins ${SUMS_SHA}"
    [ "$(awk '{print $2}' "${dir}/SHA256SUMS" | LC_ALL=C sort | tr '\n' ' ')" = "images.env ${ARCHIVE} " ] ||
        die "SHA256SUMS of ${TAG} does not list exactly ${ARCHIVE} and images.env"
    (cd "${dir}" && sha256sum --quiet -c SHA256SUMS) || die "an asset of ${TAG} does not match SHA256SUMS"
    [ "$(tar -tzf "${dir}/${ARCHIVE}" | cut -d/ -f1 | LC_ALL=C sort -u)" = "mica-build-env-${TAG}" ] ||
        die "${ARCHIVE} does not have the top directory mica-build-env-${TAG}"
}

fetch() {
    if [ -f "${DIR}/SHA256SUMS" ] && [ -d "${DIR}/mica-build-env-${TAG}" ]; then
        verify "${DIR}"
        return 0
    fi
    mkdir -p "${CACHE}"
    local work
    work="$(mktemp -d "${CACHE}/.fetch.XXXXXX")"
    trap 'rm -rf "${work}"' EXIT
    get() { curl -fsSL --max-time 300 -o "${work}/$1" "${URL}/${TAG}/$1" || die "downloading $1 of ${TAG} from ${URL} failed"; }
    get SHA256SUMS
    local got
    got="$(sha256sum "${work}/SHA256SUMS" | cut -d' ' -f1)"
    [ "${got}" = "${SUMS_SHA}" ] || die "SHA256SUMS of ${TAG} hashes to ${got}; build-env.env pins ${SUMS_SHA}"
    get "${ARCHIVE}"
    get images.env
    verify "${work}"
    tar -xzf "${work}/${ARCHIVE}" -C "${work}"
    rm -rf "${DIR}"
    mv "${work}" "${DIR}"
    trap - EXIT
    echo "build-env.sh: mica-build-env ${TAG} verified in ${DIR#"${REPO_ROOT}"/}"
}

case "${1-}" in
fetch)
    [ "$#" -eq 1 ] || die "fetch takes no argument"
    fetch
    ;;
image)
    [ "$#" -eq 2 ] && [[ "$2" =~ ^IMAGE_[A-Z0-9_]+$ ]] || die "usage: image IMAGE_<NAME>"
    fetch >/dev/null
    value="$(sed -n "s/^$2=//p" "${DIR}/images.env")"
    [ -n "${value}" ] || die "images.env of ${TAG} carries no $2"
    [[ "${value}" =~ ^[^[:space:]@]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] || die "$2='${value}' is not a digest pin (name:tag@sha256:<64 hex>)"
    printf '%s\n' "${value}"
    ;;
*)
    die "usage: bash tools/build-env.sh fetch | image <KEY>"
    ;;
esac

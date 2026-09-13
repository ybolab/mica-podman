#!/usr/bin/env bash
# Record which versions.env _out/podman/<arch> was built from, and refuse a stale one.
#
#   bash versions-stamp.sh --lock          # versions.env without comments: the build input
#   bash versions-stamp.sh --digest        # sha256 of the lock
#   bash versions-stamp.sh --stamp <dir>   # write <dir>/VERSIONS.env
#   bash versions-stamp.sh --check <dir>   # refuse a missing or stale stamp
#
# The stamp is over the lock so that editing a comment neither rebuilds nor
# invalidates _out/podman/<arch>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="${HERE}/versions.env"
STAMP_NAME="VERSIONS.env"
STAMP_KEY="PODMAN_VERSIONS_SHA256"

die() {
    echo "versions-stamp.sh: error: $*" >&2
    exit 1
}

[ -f "${VERSIONS_ENV}" ] || die "${VERSIONS_ENV} does not exist"

lock() {
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${VERSIONS_ENV}"
}

digest() {
    local content
    content="$(lock)"
    [ -n "${content}" ] || die "${VERSIONS_ENV} carries no assignments"
    printf '%s\n' "${content}" | sha256sum | cut -d' ' -f1
}

MODE="${1-}"
case "${MODE}" in
--lock)
    [ "$#" -eq 1 ] || die "--lock takes no argument"
    lock
    ;;
--digest)
    [ "$#" -eq 1 ] || die "--digest takes no argument"
    digest
    ;;
--stamp)
    [ "$#" -eq 2 ] || die "--stamp takes the output directory"
    [ -d "$2" ] || die "--stamp was given '$2', which is not a directory"
    printf '%s=%s\n' "${STAMP_KEY}" "$(digest)" >"$2/${STAMP_NAME}"
    ;;
--check)
    [ "$#" -eq 2 ] || die "--check takes the output directory"
    out="$2"
    [ -d "${out}" ] || die "--check was given '${out}', which is not a directory"
    stamp="${out}/${STAMP_NAME}"
    want="$(digest)"
    rebuild="MICA_ARCH=$(basename "${out}") make podman"
    [ -f "${stamp}" ] || {
        echo "error: ${out} carries no ${STAMP_NAME}, so its binaries cannot be matched to versions.env; rebuild: ${rebuild}" >&2
        exit 1
    }
    got="$(sed -n "s/^${STAMP_KEY}=//p" "${stamp}")"
    [ -n "${got}" ] || {
        echo "error: ${stamp} defines no ${STAMP_KEY}; rebuild: ${rebuild}" >&2
        exit 1
    }
    [ "${got}" = "${want}" ] || {
        echo "error: ${out} was built from a different versions.env than the one in this tree.
  stamped:  ${got}
  current:  ${want}
Rebuild -- ${rebuild} -- or restore versions.env." >&2
        exit 1
    }
    ;;
*)
    echo "usage: bash versions-stamp.sh --lock | --digest | --stamp <dir> | --check <dir>" >&2
    exit 1
    ;;
esac

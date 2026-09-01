#!/usr/bin/env bash
# What pkgs/podman/out-<arch> was built FROM, written into it and read back
# out of it.
#
#   bash pkgs/podman/versions-stamp.sh --lock          # the build's input
#   bash pkgs/podman/versions-stamp.sh --digest        # its sha256
#   bash pkgs/podman/versions-stamp.sh --stamp <dir>   # write <dir>/VERSIONS.env
#   bash pkgs/podman/versions-stamp.sh --check <dir>   # refuse a stale one
#
# THE DEFECT THIS CLOSES is named in pkgs/podman/build.sh's own words:
# "a stale out/ from the other architecture looks exactly like a fresh one to
# anything that only checks the files are present". The directory-per-
# architecture naming answered the second half of that sentence; the first half
# -- stale -- was left open, and out-<arch> is reused rather than rebuilt by
# pkgs/podman/deb/podman/prepare.sh and staged as it stands by
# rootfs/build.sh. Bump a version in versions.env, and both would go on
# packaging and shipping the binaries compiled from the version before it, with
# every check green: the seven files are all present, all executable, and all
# the right architecture. The only thing wrong with them is which sources they
# came from, and nothing on disk recorded that.
#
# THE STAMP IS OVER THE LOCK, NOT OVER versions.env. build.sh derives
# versions.lock by stripping comments and blank lines, and the lock is what
# pkgs/podman/Dockerfile COPYs -- that file says why, and it is measured: a
# paragraph of prose added to versions.env invalidated every compile stage
# below it, two hours of recompiling to record a rationale. A stamp over the
# raw file would put that cost back and put it somewhere worse, because it
# would refuse a directory that is genuinely current. The lock is the build's
# actual input, so the lock is what the stamp is a claim about.
#
# ONE NORMALISATION, and this file is it. build.sh writes versions.lock through
# --lock rather than keeping its own sed, because a second spelling of "strip
# comments and blank lines" is a second answer to "what did this build read",
# and the day the two disagree the stamp is a number that matches nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="${HERE}/versions.env"
# The file the stamp is written into. Named beside SHA256SUMS and NEEDED.txt,
# which are the other two records pkgs/podman/Dockerfile's verify stage
# leaves in the export, and in the KEY=value shape pkgs/rauc's
# RAUC_VERSION.env already uses for the same job.
STAMP_NAME="VERSIONS.env"
STAMP_KEY="PODMAN_VERSIONS_SHA256"

die() {
    echo "versions-stamp.sh: error: $*" >&2
    exit 1
}

[ -f "${VERSIONS_ENV}" ] ||
    die "${VERSIONS_ENV} does not exist. It is the pinned upstream set this whole build is a function of; there is no default for it"

# Comments and blank lines out, nothing else touched -- the expression
# build.sh carried inline until this file existed.
lock() {
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${VERSIONS_ENV}"
}

digest() {
    local content
    content="$(lock)"
    # An empty lock would hash to the digest of nothing, which is a perfectly
    # stable number that every empty versions.env in history agrees on -- so a
    # file that had lost its assignments would stamp and re-verify happily.
    [ -n "${content}" ] ||
        die "${VERSIONS_ENV} carries no assignments once comments and blank lines are stripped. The build would clone nothing, and a stamp over an empty input is a stamp every empty input matches"
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
    [ "$#" -eq 2 ] || die "--stamp takes the output directory to write ${STAMP_NAME} into"
    [ -d "$2" ] || die "--stamp was given '$2', which is not a directory. The stamp belongs beside the binaries it describes"
    printf '%s=%s\n' "${STAMP_KEY}" "$(digest)" >"$2/${STAMP_NAME}"
    ;;
--check)
    [ "$#" -eq 2 ] || die "--check takes the output directory to verify"
    out="$2"
    [ -d "${out}" ] || die "--check was given '${out}', which is not a directory"
    stamp="${out}/${STAMP_NAME}"
    want="$(digest)"
    # An ABSENT stamp is refused, not tolerated. A directory built before this
    # file existed, or assembled by hand, holds seven plausible binaries and no
    # claim at all about what they were compiled from -- which is the exact
    # state this stamp exists to make impossible. Tolerating it would mean the
    # guard is skipped precisely on the directories nothing has ever checked.
    [ -f "${stamp}" ] || {
        echo "error: ${out} carries no ${STAMP_NAME}, so nothing there says which versions.env it was built from. That is either a directory built before the stamp existed or one assembled by hand; either way its binaries cannot be matched to a source pin. Rebuild it: MOS_ARCH=$(basename "${out}" | sed 's/^out-//') make podman" >&2
        exit 1
    }
    got="$(sed -n "s/^${STAMP_KEY}=//p" "${stamp}")"
    [ -n "${got}" ] || {
        echo "error: ${stamp} exists and defines no ${STAMP_KEY}. The file is written by this script and by nothing else, so it has been truncated or edited by hand; rebuild: MOS_ARCH=$(basename "${out}" | sed 's/^out-//') make podman" >&2
        exit 1
    }
    [ "${got}" = "${want}" ] || {
        echo "error: ${out} was built from a different pkgs/podman/versions.env than the one in this tree.
  stamped:  ${got}
  current:  ${want}
Those binaries are the versions.env of some earlier build, and every check that
only looks at the files would pass over them: seven binaries, present,
executable and the right architecture. Rebuild them -- MOS_ARCH=$(basename "${out}" | sed 's/^out-//') make podman -- or put versions.env back to what they were compiled from." >&2
        exit 1
    }
    ;;
*)
    echo "usage: bash pkgs/podman/versions-stamp.sh --lock | --digest | --stamp <dir> | --check <dir>" >&2
    exit 1
    ;;
esac

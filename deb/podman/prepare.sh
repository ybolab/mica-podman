#!/usr/bin/env bash
# The podman producer's PREPARE hook: put the seven container-engine binaries in
# MOS_DEB_STAGE for build-env/deb/build.sh to hand the packaging build as its
# `bin` context.
#
# WHY A HOOK AND NOT A KEY IN producer.env. The binaries are compiled by
# pkgs/podman/build.sh -- six upstream clones verified against their pinned
# source hashes, across four language toolchains, the whole of it under
# emulation for arm64. That is an input to a compile, not to a docker build, and
# no producer.env key describes it. The generic driver packs what it is handed;
# this decides what it is handed.
#
# EXISTING OUTPUT IS REUSED. pkgs/podman/build.sh writes out-<arch>/ and a
# cold arm64 build of it takes roughly three quarters of an hour, so a complete
# one is used as it stands -- the same directory, and the same reuse,
# rootfs/build.sh stages into an image. It is rebuilt only when a binary
# is missing from it. The directory carries the architecture in its name, so the
# other architecture's output cannot be mistaken for this one's -- and since
# pkgs/podman/versions-stamp.sh exists, a directory compiled from a
# superseded versions.env cannot be mistaken for a current one either, which is
# the half of that sentence the naming never covered.
#
# PRE-FLIGHT MODE. Run with MOS_DEB_PREFLIGHT=1 by build-env/deb/preflight.sh
# and declared with PREFLIGHT="1" in this producer's producer.env, this hook
# reports whether out-<arch> is there, complete and stamped -- and BUILDS
# NOTHING. That opt-in is what makes it safe: the pre-flight runs before any
# producer starts, and a hook that had not been taught the variable would start
# three quarters of an hour of emulated compiling instead of answering a
# question. It is also the most expensive late discovery this repository has,
# which is why this hook is the second to learn the mode.
set -euo pipefail

PREFLIGHT="${MOS_DEB_PREFLIGHT:-0}"

# MOS_DEB_STAGE is required to STAGE, and there is nothing to stage in
# pre-flight mode: the driver has not created a stage, because no build has
# started. Every other variable is required either way.
for v in MOS_DEB_REPO_ROOT MOS_DEB_ARCH MOS_DEB_PRODUCER; do
    [ -n "${!v:-}" ] || {
        echo "error: ${v} is not set. This script is pkgs/podman/deb/podman/producer.env's PREPARE hook and is run by build-env/deb/build.sh, which sets it; it is not a standalone command" >&2
        exit 1
    }
done
[ "${PREFLIGHT}" != 0 ] || [ -n "${MOS_DEB_STAGE:-}" ] || {
    echo "error: MOS_DEB_STAGE is not set. This script is pkgs/podman/deb/podman/producer.env's PREPARE hook and is run by build-env/deb/build.sh, which sets it; it is not a standalone command" >&2
    exit 1
}

REPO_ROOT="${MOS_DEB_REPO_ROOT}"
ARCH="${MOS_DEB_ARCH}"
STAGE="${MOS_DEB_STAGE:-}"
BUILD_SH="${REPO_ROOT}/pkgs/podman/build.sh"
VERSIONS_STAMP_SH="${REPO_ROOT}/pkgs/podman/versions-stamp.sh"
OUT="${REPO_ROOT}/pkgs/podman/out-${ARCH}"

[ -f "${BUILD_SH}" ] || {
    echo "error: ${BUILD_SH} does not exist; it is what compiles the binaries this producer packages" >&2
    exit 1
}
[ -f "${VERSIONS_STAMP_SH}" ] || {
    echo "error: ${VERSIONS_STAMP_SH} does not exist; it is what records which versions.env out-<arch> was compiled from and what refuses a directory compiled from another one" >&2
    exit 1
}

case "${ARCH}" in
amd64) ELF_ARCH=x86-64 ;;
arm64) ELF_ARCH=aarch64 ;;
*)
    echo "error: MOS_DEB_ARCH is '${ARCH}'. pkgs/podman/build.sh builds amd64 and arm64 and no other, and this producer's ARCHES says the same" >&2
    exit 1
    ;;
esac

# THE SET THIS PRODUCER OWNS, and the only set it stages. pkgs/podman builds
# exactly these and rootfs/scripts/podman-install.sh installs exactly these.
BINARIES=(podman quadlet crun conmon netavark aardvark-dns catatonit)

missing=""
for b in "${BINARIES[@]}"; do
    [ -f "${OUT}/${b}" ] || missing="${missing} ${b}"
done

# ------------------------------------------------------------- pre-flight
#
# Everything this hook can answer without compiling: the seven binaries, and
# the stamp that says which versions.env they came from. All three counts are
# printed on BOTH paths, which is the contract build-env/deb/preflight.sh
# refuses a hook for breaking.
#
# THE TWO CATEGORIES ARE DECIDED BY WHAT THE NORMAL PATH BELOW WOULD DO, and
# this block mirrors it rather than making its own judgement:
#
#   binaries absent  -> the normal path BUILDS them. So this is a WARNING: the
#                       run succeeds, it just spends three quarters of an hour
#                       somewhere the operator did not expect, and saying so in
#                       advance is the whole point. Refusing instead would mean
#                       `make os-debs` could no longer build a pool on a fresh
#                       host -- which its own help line promises -- and would
#                       be arbitrary besides, since the mosd, mqtt and rauc
#                       hooks compile from their hooks too.
#   stamp stale      -> the normal path REFUSES. So this is MISSING.
#
# THE STAMP IS ONLY CHECKED WHEN THE BINARIES ARE COMPLETE, for the same
# reason: a build rewrites the stamp, so a stale one under an incomplete
# directory is a fact that the run itself is about to erase. Reporting it would
# be reporting a state that cannot survive the next five minutes.
if [ "${PREFLIGHT}" != 0 ]; then
    # Seven binaries plus one stamp, examined either way -- the stamp is part
    # of what this producer needs whether or not this run finds it wanting.
    examined=$((${#BINARIES[@]} + 1))
    n_missing=0
    n_warned=0
    reports=()
    # ONE report for the binaries, naming all of them, rather than one per
    # file. Seven absent binaries have one cause and one command between them,
    # and seven copies of that sentence is a wall the real second cause -- a
    # stale stamp -- would be lost in. The COUNT still moves by seven: the
    # report shape and the number are separate on purpose, which is why the
    # contract carries the number rather than leaving it to be inferred.
    if [ -n "${missing}" ]; then
        for b in ${missing}; do n_warned=$((n_warned + 1)); done
        reports+=("warning: ${OUT} is missing ${n_warned} of its ${#BINARIES[@]} binaries:${missing}.
This producer builds them itself, so the run will not stop -- it will spend
roughly three quarters of an hour compiling six upstream clones across four
language toolchains, under emulation for arm64, from inside a packaging hook.
Run 'MOS_ARCH=${ARCH} make podman' first to pay that cost where it can be seen.")
    else
        stamp_out=""
        stamp_rc=0
        stamp_out="$(bash "${VERSIONS_STAMP_SH}" --check "${OUT}" 2>&1)" || stamp_rc=$?
        [ "${stamp_rc}" -eq 0 ] || {
            reports+=("${stamp_out}")
            n_missing=$((n_missing + 1))
        }
    fi
    [ "${#reports[@]}" -eq 0 ] || printf '%s\n\n' "${reports[@]}" >&2
    echo "preflight-examined: ${examined}"
    echo "preflight-missing: ${n_missing}"
    echo "preflight-warned: ${n_warned}"
    if [ "${n_missing}" -gt 0 ]; then
        echo "prepare.sh: refusing to build mos-podman: ${OUT} holds all ${#BINARIES[@]} binaries and they were compiled from a versions.env this tree no longer has. Nothing was built and no container was started." >&2
        exit 1
    fi
    if [ "${n_warned}" -gt 0 ]; then
        echo "prepare.sh: mos-podman will build ${n_warned} of its ${examined} inputs during the run (${OUT})" >&2
        exit 0
    fi
    echo "prepare.sh: pre-flight found all ${examined} inputs of mos-podman present and stamped for ${ARCH} (${OUT})"
    exit 0
fi

if [ -n "${missing}" ]; then
    echo "prepare: ${OUT} is missing${missing}; building the engine for ${ARCH}"
    MOS_ARCH="${ARCH}" bash "${BUILD_SH}"
    for b in "${BINARIES[@]}"; do
        [ -f "${OUT}/${b}" ] || {
            echo "error: pkgs/podman/build.sh reported success and ${OUT}/${b} does not exist" >&2
            exit 1
        }
    done
else
    echo "prepare: reusing the existing ${OUT}"
fi

# WHICH versions.env THESE CAME FROM, checked on the REUSE path too and not
# only after a build -- the same reason the architecture check below is, and
# the same failure shape. A complete out-<arch> compiled from a superseded
# versions.env is seven binaries that are present, executable and the right
# architecture, and every check that stops there passes over them.
#
# REFUSED rather than rebuilt, unlike the missing-binary path above. A version
# bump is an act: versions.env is this project's upgrade interface, and the
# command that carries it out is `make podman`. Silently starting three
# quarters of an hour of emulated compiling from inside a packaging hook is the
# late, expensive surprise the pre-flight above exists to end, so it is not
# what a stale stamp should trigger.
bash "${VERSIONS_STAMP_SH}" --check "${OUT}"

# The architecture, checked on the REUSE path too and not only after a build.
# out-<arch> is a directory in the worktree that nothing here created, and
# packing an amd64 binary into an arm64 archive is a failure dpkg-shlibdeps
# reports as a missing dependency rather than as a wrong architecture.
for b in "${BINARIES[@]}"; do
    got="$(file -b "${OUT}/${b}")"
    case "${got}" in
    *"ELF 64-bit"*"${ELF_ARCH}"*) ;;
    *)
        echo "error: ${OUT}/${b} is not an ${ELF_ARCH} ELF: ${got}. That directory holds the output of \`MOS_ARCH=${ARCH} make podman\`; delete it and build again" >&2
        exit 1
        ;;
    esac
done

# Re-asserted immediately before the copy, and not only where the environment
# is read. ${STAGE} is optional in this script now -- pre-flight mode has no
# stage -- so an empty one reaching here would make every destination below
# `/${b}`, and seven container-engine binaries would be written into the root
# of whatever filesystem this ran on. Measured, by a mutation that skipped the
# pre-flight branch: it wrote /podman, /quadlet, /crun, /conmon, /netavark,
# /aardvark-dns and /catatonit, and reported success.
[ -n "${STAGE}" ] || {
    echo "error: MOS_DEB_STAGE is empty at the point of staging. The seven destinations would each be an absolute path at the filesystem root" >&2
    exit 1
}
for b in "${BINARIES[@]}"; do
    cp "${OUT}/${b}" "${STAGE}/${b}"
done

# What pkgs/podman/build.sh also writes into out-<arch> -- SHA256SUMS, and
# anything a later revision of it adds -- stays there. The `bin` context is what
# the payload is built from, and a file in it that no COPY names is a file
# nothing accounts for; the payload assertion in this producer's Dockerfile is
# over the staged ROOT, so it would never see it.
echo "prepare: staged ${BINARIES[*]} for ${ARCH} into ${STAGE}"

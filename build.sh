#!/usr/bin/env bash
# Build the container engine from upstream source into seven aarch64 binaries.
#
#   bash build.sh
#   → out/{podman,quadlet,crun,conmon,netavark,aardvark-dns,catatonit}
#
# A script rather than a bare `docker buildx build` in the Makefile, for one
# reason: the builder selection below. The first run of this build failed with
# `exec /bin/sh: exec format error` because the default buildx builder cannot
# execute linux/arm64 — and rootfs/build.sh had already solved exactly
# that, with the same fallback, forty lines of its own. Duplicating the
# invocation in a Makefile recipe would have duplicated the bug too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file sits at the repository root; build-env/from.sh is reached through
# it (build-env/ is the mica-build-env source pin, fetched by tools/deps.sh),
# and a relative path here would resolve against whatever directory the
# caller happened to be in.
REPO_ROOT="${HERE}"
FROM_SH="${REPO_ROOT}/build-env/from.sh"
[ -f "${FROM_SH}" ] || {
    echo "error: ${FROM_SH} does not exist. build.sh derives REPO_ROOT as its own directory; run `make deps` to fetch the substrate at its pin" >&2
    exit 1
}

# MOS_ARCH selects the target. The output directory follows it, so an arm64 and
# an amd64 set can coexist: one shared out/ would mean every board switch is a
# full recompile of four language toolchains, and -- worse -- a stale out/ from
# the other architecture looks exactly like a fresh one to anything that only
# checks the files are present.
MOS_ARCH="${MOS_ARCH:-arm64}"
case "${MOS_ARCH}" in
arm64) ELF_ARCH=aarch64 ;;
amd64) ELF_ARCH=x86-64 ;;
*) echo "error: MOS_ARCH is '${MOS_ARCH}'; it must be arm64 or amd64" >&2; exit 1 ;;
esac
OUT="${HERE}/out-${MOS_ARCH}"

# The src stage runs at the BUILD platform, not the target's, so this build
# needs mos-build-base at the host's architecture as well -- a second image
# with a second name, since a LOCAL_ tag carries its architecture. The mapping
# is build-env/build.sh's, copied rather than inferred from MOS_ARCH: the
# host is what it is regardless of what is being built for, and reading it off
# MOS_ARCH would make every cross build resolve the src base to the target.
#
# `uname -m` and not `docker buildx inspect`: on this host inspect reports the
# mos-arm64 builder as `linux/amd64, linux/386` while a throwaway build on it
# prints `aarch64` (docs/design/build-harness.md section 5), so it is not
# something to decide an architecture with. What is wanted here is narrower
# anyway -- which architecture $BUILDPLATFORM will be -- and that is the
# machine buildkit runs on, which for every builder this script selects is
# this one.
case "$(uname -m)" in
x86_64) NATIVE_ARCH=amd64 ;;
aarch64 | arm64) NATIVE_ARCH=arm64 ;;
*) echo "error: $(uname -m) is not an architecture build.sh maps to a mos-build-* tag, so it cannot resolve the src stage's base for the build platform. build-env/build.sh maps the same two and no more" >&2; exit 1 ;;
esac

for tool in docker; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "error: ${tool} is required and not on PATH" >&2
        exit 1
    }
done

# The builder is NAMED rather than inherited, and named rather than pinned --
# the same BUILDX_BUILDER register as rootfs/build.sh, and the same block as
# pkgs/rauc/build.sh. BUILDX_BUILDER wins, because a caller who names a
# builder has made a decision; with nothing named, `default` is the docker
# driver on every docker installation. What must not happen is inheriting the
# ambient selection: a leftover `mos-rauc-arm64` from an unrelated build is a
# plausible current builder on any host that has ever run `make os-rauc`.

# `default` reaches linux/${MOS_ARCH} exactly when the host has binfmt
# registered for it. When it does not, this no longer refuses: it selects the
# `mos-${MOS_ARCH}` docker-container builder, whose buildkit image bundles the
# emulators and needs no host registration -- same name and creation path as
# tests/quadlet-doc-test.sh. That it genuinely executes the target
# architecture is measured rather than inspected: `docker buildx ls` reports
# mos-arm64 as linux/amd64 (+3), linux/386 on this host, and a throwaway
# `FROM localhost/mos-build-base` + `RUN uname -m` built with
# `--builder mos-arm64 --platform linux/arm64` printed aarch64.

# What that driver cannot do is resolve a `localhost/mos-build-*` FROM: it has
# its own content store and reads `localhost/` as a registry hostname, measured
# as `Head "http://localhost/v2/mos-build-base/manifests/latest": dial tcp
# [::1]:80: connect: connection refused` against a FROM line that is correct.
# That is closed below rather than refused: build-env/from.sh --contexts=
# hands the bases over as CONTENT, as OCI layouts named after the tags they
# came from, and the Dockerfile keeps saying FROM ${MOS_BUILD_C}.
if [ -n "${BUILDX_BUILDER:-}" ]; then
    echo "note: using the builder BUILDX_BUILDER names (${BUILDX_BUILDER})"
    BUILDER="${BUILDX_BUILDER}"
else
    # The whole output is captured before anything reads it, rather than piped
    # into a grep. An early-exiting `grep -q` on the right of a pipe closes it
    # the moment it matches; under `set -o pipefail` the producer then dies of
    # SIGPIPE and the pipeline reports failure exactly when the pattern IS
    # found -- so this would pick the container builder on the hosts that can
    # build natively, intermittently, depending on whether the output fit the
    # pipe buffer first. tests/shell-pipefail-lint.sh exists for this one
    # mistake and caught this line.
    default_platforms="$(docker buildx inspect default 2>/dev/null || true)"
    if printf '%s\n' "${default_platforms}" | grep -c "linux/${MOS_ARCH}" >/dev/null; then
        BUILDER=default
    else
        BUILDER="mos-${MOS_ARCH}"
        docker buildx inspect "${BUILDER}" >/dev/null 2>&1 ||
            docker buildx create --name "${BUILDER}" --driver docker-container >/dev/null
    fi
fi
BUILDER_ARGS=(--builder "${BUILDER}")

# Which driver it turned out to be decides whether the bases go over as tags or
# as layouts, so it is read off the builder rather than inferred from its name:
# BUILDX_BUILDER may name anything.
builder_inspect="$(docker buildx inspect "${BUILDER}" 2>/dev/null || true)"
BUILDER_DRIVER="$(printf '%s\n' "${builder_inspect}" | sed -n 's/^Driver:[[:space:]]*//p')"
[ -n "${BUILDER_DRIVER}" ] || {
    echo "error: \`docker buildx inspect ${BUILDER}\` names no driver, so this build cannot tell whether that builder can resolve a localhost/mos-build-* tag or has to be handed the bases as OCI layouts. Either the builder does not exist or it is not running: \`docker buildx ls\` lists what does" >&2
    exit 1
}

# The refusal that is left, and it is about the one builder this script may not
# replace. A caller who named BUILDX_BUILDER named it deliberately, so a
# docker-driver builder on a host with no binfmt for ${MOS_ARCH} is a dead end
# here rather than something to silently route around -- and it is refused now
# instead of surfacing as `exec /bin/sh: exec format error` inside a compile
# stage, which is how the first run of this build failed. Note what it does NOT
# say any more: host binfmt is no longer what this build needs, only what THAT
# builder needs.
if [ "${BUILDER_DRIVER}" = docker ] &&
    ! printf '%s\n' "${builder_inspect}" | grep -c "linux/${MOS_ARCH}" >/dev/null; then
    echo "error: the buildx builder '${BUILDER}' uses the docker driver and does not offer linux/${MOS_ARCH} on this host, so every RUN in Dockerfile would fail with 'exec format error'. Either register the emulator on the HOST -- docker run --privileged --rm tonistiigi/binfmt --install ${MOS_ARCH} -- or unset BUILDX_BUILDER and let this script select the docker-container builder 'mos-${MOS_ARCH}', whose buildkit image bundles the emulators and needs no host registration" >&2
    exit 1
fi

# NO image-libs.txt, and no rootfs prerequisite. An earlier revision generated
# a soname list out of the PACKED rootfs and had the verify stage diff every
# binary's NEEDED against it. That was wrong twice over:
#
#   * It checked the PREVIOUS image. The binaries built here go into the NEXT
#     one, whose package list this build has not seen.
#   * It was a cycle. rootfs/build.sh now stages out, so the
#     rootfs needed the engine and the engine's check needed the rootfs; a
#     clean checkout could build neither.
#
# The check moved to rootfs/scripts/podman-assert.sh, where it runs `ldd`
# against the
# real binaries in the assembled root under emulation. That is the loader's own
# answer about the image being shipped, not a list compared to a list.


# The Dockerfile's src stage COPYs this, not versions.env itself, so that
# editing a comment in versions.env does not invalidate every compile stage
# below it.
#
# The stripping is versions-stamp.sh's and no longer this
# script's: that file also computes the digest the export is stamped with at
# the bottom of this script, and a build that normalised versions.env one way
# and stamped it another would record a number describing an input it had not
# used.
VERSIONS_STAMP_SH="${HERE}/versions-stamp.sh"
[ -f "${VERSIONS_STAMP_SH}" ] || {
    echo "error: ${VERSIONS_STAMP_SH} does not exist; it is what derives versions.lock and what stamps the export with the digest of it" >&2
    exit 1
}
bash "${VERSIONS_STAMP_SH}" --lock >"${HERE}/versions.lock"
if [ ! -s "${HERE}/versions.lock" ]; then
    echo "error: versions.lock came out empty from versions.env; the src stage would clone nothing and the failure would surface as a missing binary" >&2
    exit 1
fi

# The four builder images, resolved out of build-env/images.env before
# anything is deleted or built. Dockerfile declares them with no
# defaults, so a missing one is refused here by name -- with the command that
# makes it -- rather than by docker, which reports a missing localhost tag as a
# failed pull from a registry called `localhost`.

# --arch is passed, and it is the check this pinning added. A local tag carries
# exactly one architecture, unlike the multi-architecture digests images.env
# pins for upstream bases, so `MOS_ARCH=arm64 make podman` against an amd64
# builder family has to be refused. Left to docker it surfaces as "no match for
# platform in manifest" against a FROM line that is correct.
mapfile -t FROM_ARGS < <("${FROM_SH}" --arch="${MOS_ARCH}" \
    MOS_BUILD_BASE=LOCAL_MOS_BUILD_BASE \
    MOS_BUILD_C=LOCAL_MOS_BUILD_C \
    MOS_BUILD_GO=LOCAL_MOS_BUILD_GO \
    MOS_BUILD_RUST=LOCAL_MOS_BUILD_RUST)
# mapfile itself cannot fail, so its exit status says nothing about the process
# inside the substitution; an empty array is what a refusal looks like from
# here, and an empty array would build with no --build-arg at all.
[ "${#FROM_ARGS[@]}" -eq 8 ] || {
    echo "error: build-env/from.sh did not yield the four builder images (see its message above); this build would have run with an unpinned or missing FROM" >&2
    exit 1
}

# The fifth argument, and the only one resolved at a different architecture.
# A separate call because --arch is per-invocation and this one is per-image:
# LOCAL_MOS_BUILD_BASE at ${NATIVE_ARCH} is a different tag from the same key
# at ${MOS_ARCH}, and it is the src stage's base. Folding it into the call
# above would have to drop --arch, and dropping --arch is what from.sh refuses
# by name -- both families are in the store at once, so there is no "the"
# local image to fall back to.
#
# On a native build the two resolve to the SAME tag, and that is left to
# happen rather than special-cased: two --build-arg names may carry one value,
# and a build where they differ and a build where they do not then take the
# same path through this script.
mapfile -t NATIVE_ARGS < <("${FROM_SH}" --arch="${NATIVE_ARCH}" \
    MOS_BUILD_BASE_NATIVE=LOCAL_MOS_BUILD_BASE)
[ "${#NATIVE_ARGS[@]}" -eq 2 ] || {
    echo "error: build-env/from.sh did not yield localhost/mos-build-base:${NATIVE_ARCH} (see its message above); the src stage's FROM would have been blank. That family is built by \`MOS_BUILD_PLATFORM=linux/${NATIVE_ARCH} make build-env\` -- a cross build needs BOTH families on this host, the target's for the compiles and the host's for the source fetch" >&2
    exit 1
}

# The same four images a second time, as content, for a builder that cannot
# read the local image store. Only for that builder: with the docker driver the
# tags above resolve directly, and exporting them anyway would copy the whole
# mos-build family -- 3.6 GB of it -- to disk on every native build to change
# nothing.
#
# A temporary directory rather than a path in the tree, because the layouts are
# a copy of what the image store already holds -- they have no life beyond this
# build and nothing may ever read them as an input to the next one.
CTX_ARGS=()
if [ "${BUILDER_DRIVER}" != docker ]; then
    OCI_DIR="$(mktemp -d)"
    trap 'rm -rf "${OCI_DIR}"' EXIT
    mapfile -t CTX_ARGS < <("${FROM_SH}" --arch="${MOS_ARCH}" --contexts="${OCI_DIR}" \
        LOCAL_MOS_BUILD_BASE \
        LOCAL_MOS_BUILD_C \
        LOCAL_MOS_BUILD_GO \
        LOCAL_MOS_BUILD_RUST)
    [ "${#CTX_ARGS[@]}" -eq 8 ] || {
        echo "error: build-env/from.sh did not yield the four OCI layout contexts (see its message above); the '${BUILDER}' builder would have resolved the FROM lines as pulls from a registry called 'localhost'" >&2
        exit 1
    }
    # A fifth layout for the src stage's base, and ONLY when it is a fifth
    # image. On a native build MOS_BUILD_BASE_NATIVE resolves to the tag the
    # loop above already exported, and a second --build-context under the same
    # name would be one name bound twice -- an export of 300 MB to say what has
    # already been said, and a precedence question nothing here should have to
    # answer.
    if [ "${NATIVE_ARCH}" != "${MOS_ARCH}" ]; then
        mapfile -t NATIVE_CTX < <("${FROM_SH}" --arch="${NATIVE_ARCH}" --contexts="${OCI_DIR}" \
            LOCAL_MOS_BUILD_BASE)
        [ "${#NATIVE_CTX[@]}" -eq 2 ] || {
            echo "error: build-env/from.sh did not yield the OCI layout for localhost/mos-build-base:${NATIVE_ARCH} (see its message above); the '${BUILDER}' builder would have resolved the src stage's FROM as a pull from a registry called 'localhost'" >&2
            exit 1
        }
        CTX_ARGS+=("${NATIVE_CTX[@]}")
    fi
fi

rm -rf "${OUT}"
mkdir -p "${OUT}"

docker buildx build "${BUILDER_ARGS[@]}" \
    --platform "linux/${MOS_ARCH}" \
    "${FROM_ARGS[@]}" \
    "${NATIVE_ARGS[@]}" \
    ${CTX_ARGS[@]+"${CTX_ARGS[@]}"} \
    --build-arg "ELF_ARCH=${ELF_ARCH}" \
    -f "${HERE}/Dockerfile" \
    -o "${OUT}" \
    "${HERE}"

# The Dockerfile's own stage already refuses a wrong-architecture artifact, a
# dynamically linked catatonit, or a NEEDED soname the image does not carry. This re-checks the EXPORTED tree, which is a different claim: the
# stage asserts what it built, this asserts what landed on disk for
# rootfs/build.sh to stage. An export that dropped a file, or a cache hit
# that served an older layer, is invisible to the first check and caught here.
missing=""
for b in podman quadlet crun conmon catatonit netavark aardvark-dns; do
    [ -f "${OUT}/${b}" ] || missing="${missing} ${b}"
done
[ -z "${missing}" ] || {
    echo "error: the build reported success but these binaries are not in ${OUT}:${missing}" >&2
    exit 1
}

# WHAT THESE BINARIES WERE COMPILED FROM, recorded beside them. Everything
# above this line checks that the files are present, executable and the right
# architecture -- and the comment at the top of this script has always said
# what that leaves open: "a stale out/ from the other architecture looks
# exactly like a fresh one to anything that only checks the files are
# present". Reuse is the normal path (prepare.sh reuses a complete directory,
# build.sh stages one as it stands), so without this the version bump that
# is this project's whole upgrade interface can be made, committed and shipped
# while the device keeps running the engine from before it.
#
# Written on the HOST rather than exported from the Dockerfile, and safe there
# for one reason: versions.lock is the src stage's COPY, so it is part of the
# cache key of every stage below it. A build that served cached layers served
# them for THIS lock; a changed lock invalidates the whole chain. So the digest
# this script computes cannot describe an input the build did not use.
bash "${VERSIONS_STAMP_SH}" --stamp "${OUT}"

echo
echo "=== ${OUT} ==="
for b in podman quadlet crun conmon catatonit netavark aardvark-dns; do
    printf '  %-14s %8s KiB  %s\n' "${b}" \
        "$(($(stat -c%s "${OUT}/${b}") / 1024))" \
        "$(file -b "${OUT}/${b}" 2>/dev/null | cut -c1-46)"
done
total=$(du -sb "${OUT}" | cut -f1)
printf '  %-14s %8s KiB\n' "TOTAL" "$((total / 1024))"

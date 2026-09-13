# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# The podman producer: the `mica-podman` package.
#
#   make os-deb-podman  ->  build-env/deb/build.sh --producer podman --arch <amd64|arm64>
#
# This file only STAGES, ASSERTS and PACKS. The seven binaries were compiled by
# this producer's PREPARE hook -- build.sh, six pinned upstreams
# across four toolchains -- and arrive through the `bin` context; the container
# configuration arrives through `overlay`, which is rootfs/overlay and the
# tree that owns those files today.
#
# This stage runs at the TARGET architecture because dpkg-shlibdeps resolves an
# ELF's dependencies against the libraries of the container it runs in, and
# build-env/deb/pack.sh refuses the mismatch by name. There are seven ELF
# payloads here, so that is the whole reason this producer is not
# Architecture: all.
#
# No default for the base, for the reason build-env/deb/Dockerfile gives: a
# driver that failed to pass the argument would otherwise build from a floating
# tag.
ARG MICA_BUILD_DEB

FROM ${MICA_BUILD_DEB} AS pack

# THE RUNTIME LIBRARIES THE PAYLOAD LINKS AGAINST, present so dpkg-shlibdeps can
# resolve them. This is not the package's dependency list being written down: it
# is the opposite. dpkg-shlibdeps answers "what does this ELF need" by looking at
# the libraries INSTALLED NEXT TO IT, in this container -- build-env/deb/README.md
# says so and it is why pack.sh refuses an architecture mismatch -- and
# mica-build-deb carries dpkg-dev and no runtime. Without these, packing dies with
# `cannot find library libjson-c.so.5 needed by .../usr/bin/crun` and the package
# is never produced. The micad producers never meet this because their Rust
# binaries need only libc, which every base carries.
#
# THE LIST IS rootfs/stages/31-feature-containers.Dockerfile'S, read from there
# rather than re-derived, and each entry's reasoning lives there: libjson-c5
# (crun 1.29.1 requires json-c, not yajl), libsubid5 and libseccomp2 (podman),
# libcap2 (crun), libglib2.0-0t64 (conmon). What follows from installing them is
# that shlibdeps EMITS them into Depends itself, with the version floors it
# derives from each library's symbols file -- floors no hand-written list could
# state and keep current. None of them is written into the control template.
#
# It runs at the TARGET architecture, like everything else in this stage, so the
# arm64 pack resolves arm64 sonames against arm64 libraries. The apt lists are a
# cache mount and `apt-get update` runs inside it every time, so the architecture
# of the lists is always this container's.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-deb-podman,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-deb-podman,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        libjson-c5 libsubid5 libseccomp2 libcap2 libglib2.0-0t64

# pack.sh comes over as a named context rather than out of the image. It is the
# packaging CONTRACT, shared by every producer, and build-env/deb/README.md
# requires this shape: an edit to the packer then takes effect without
# rebuilding the whole builder family.
COPY --from=packer pack.sh /usr/local/bin/pack.sh

COPY control/ /in/control/
COPY copyright payload.manifest /in/

# The four configuration files podman actually reads, and the Quadlet mount
# unit, at the paths rootfs/scripts/overlay-install.sh installs them to.
# PLAN-036 section 3: "Podman's configuration and Quadlet mount belong to
# mica-podman, not to the common system overlay."
COPY --from=overlay etc/containers/containers.conf \
                    etc/containers/policy.json \
                    etc/containers/registries.conf \
                    etc/containers/storage.conf /in/etc/containers/
COPY --from=overlay etc/systemd/system/etc-containers-systemd.mount /in/etc/systemd/system/

COPY --from=bin podman quadlet crun conmon netavark aardvark-dns catatonit /in/bin/
# The pins those binaries were built from, staged beside them by prepare.sh.
COPY --from=bin versions.env /in/versions.env

ARG MICA_DEB_VERSION
ARG MICA_DEB_ARCH
ARG SOURCE_DATE_EPOCH
# Provenance, written into the control file by pack.sh; see build-env/deb/README.md.
ARG MICA_DEB_SOURCE_REPO
ARG MICA_DEB_SOURCE_COMMIT

# THE PAYLOAD IS rootfs/scripts/podman-install.sh's RESULT, path for path and
# mode for mode, plus the overlay's container configuration and the copyright.
# Nothing about what the rootfs chain installs changes here: rootfs/ still
# ships these files loose until a later workstream switches it, so this staging
# is a second producer of one tree and the two have to agree.
#
# Every directory is created explicitly rather than left to `install -D`, so the
# mode of each one is a decision in this file. /etc/containers and
# /etc/containers/systemd are payload of this package outright -- PLAN-036 gives
# it the subtree -- and the pool's ownership check does not flag directory
# overlap, so an omitted directory here is caught by nothing but the assertion
# below.
#
# THE GENERATOR IS A RELATIVE SYMLINK, and the target is the one
# podman-install.sh writes: ../../../libexec/podman/quadlet, resolved from
# /usr/lib/systemd/system-generators. An absolute link would name a path that is
# correct on the device and wrong inside every tool that reads the payload
# against a staging root.
#
# `docker` IS A SECOND NAME FOR podman AND NOTHING MORE, relative for the same
# reason. podman reads argv[0] to NAME ITSELF and for nothing else -- its root
# command's Use is the basename it was invoked as, so `docker --version` prints
# `docker version 5.8.6` and the usage text says docker, while every verb, flag
# and behaviour is podman's own. No mode is selected by the name.
#
# What the name does not bring is everything Docker keeps behind its socket:
# there is no daemon, no /run/docker.sock and no REST API in this image, so a
# client that dials the socket rather than exec'ing the binary is no better off
# than before. `docker compose` fails the way `podman compose` does -- measured
# against this archive: "Error: looking up compose provider failed", over seven
# candidate paths, because podman shells out to a compose provider and neither
# docker-compose nor podman-compose is payload here. Quadlet is this image's
# composition mechanism.
#
# NOT the upstream podman-docker wrapper, which is a shell script that prints
# "Emulate Docker CLI using podman" to stderr unless /etc/containers/nodocker
# exists. That file is the operator's off switch for the message, and this root
# is an immutable dm-verity squashfs: shipping the script would nail the notice
# to every invocation with no way to silence it.
#
# NO multi-user.target.wants LINK, and no maintainer script that enables
# anything. See ENABLEMENT in producer.env for both halves of why.
#
# NOT a conffile, deliberately, and the same decision the micad producers record:
# six of these paths are under /etc, but this root filesystem is an immutable
# dm-verity squashfs and nobody edits anything in it. A conffiles entry would
# promise a three-way merge that cannot happen. Do not "fix" this into one.
RUN set -eu; \
    install -d -m 0755 /stage/etc /stage/etc/containers /stage/etc/containers/systemd \
                       /stage/etc/systemd /stage/etc/systemd/system \
                       /stage/usr /stage/usr/bin /stage/usr/lib /stage/usr/lib/systemd \
                       /stage/usr/lib/systemd/system-generators \
                       /stage/usr/libexec /stage/usr/libexec/podman \
                       /stage/usr/share /stage/usr/share/doc /stage/usr/share/doc/mica-podman \
                       /stage/usr/share/mica-podman; \
    install -m 0755 /in/bin/podman /stage/usr/bin/podman; \
    install -m 0755 /in/bin/crun   /stage/usr/bin/crun; \
    for b in quadlet conmon netavark aardvark-dns catatonit; do \
        install -m 0755 "/in/bin/${b}" "/stage/usr/libexec/podman/${b}"; \
    done; \
    ln -s ../../../libexec/podman/quadlet \
          /stage/usr/lib/systemd/system-generators/podman-system-generator; \
    ln -s podman /stage/usr/bin/docker; \
    for f in containers.conf policy.json registries.conf storage.conf; do \
        install -m 0644 "/in/etc/containers/${f}" "/stage/etc/containers/${f}"; \
    done; \
    install -m 0644 /in/etc/systemd/system/etc-containers-systemd.mount \
                    /stage/etc/systemd/system/etc-containers-systemd.mount; \
    install -m 0644 /in/copyright /stage/usr/share/doc/mica-podman/copyright; \
    install -m 0644 /in/versions.env /stage/usr/share/mica-podman/versions.env

# PRODUCER INDEPENDENCE, asserted rather than described, in the form that is
# meaningful for a producer whose payload is a file set rather than a compile:
# the staged tree is EXACTLY the declared set. The micad producers assert the
# same boundary by failing when a binary they do not own turns up in their
# target directory; here the equivalent is a path -- of any kind, extra or
# missing -- that payload.manifest does not name.
#
# Both directions matter and a one-directional check is the trap. "No path
# outside the declaration" passes over an empty tree; "every declared path is
# present" passes over a tree with a stray file in it. `diff` of two sorted
# lists is both at once.
#
# The generated side reads MODE, TYPE and SYMLINK TARGET, not just the path,
# because the three things most likely to go wrong quietly are a 0644 binary, a
# regular file where the generator symlink should be, and a symlink whose target
# is right on the device and wrong everywhere else.
RUN set -eu; \
    grep -v '^#' /in/payload.manifest | grep -v '^$' | LC_ALL=C sort > /tmp/declared; \
    [ -s /tmp/declared ] || { echo "error: /in/payload.manifest declares no paths after comments are stripped. An 'is exactly' assertion over an empty declaration is one that reports green over any payload at all" >&2; exit 1; }; \
    find /stage -mindepth 1 -printf '%#m %y /%P\t%l\n' \
        | awk -F'\t' '{ if ($2 == "") print $1; else print $1 " -> " $2 }' \
        | LC_ALL=C sort > /tmp/staged; \
    if ! diff -u /tmp/declared /tmp/staged; then \
        echo "error: the staged tree is not the payload deb/podman/payload.manifest declares. '-' is declared and not staged, '+' is staged and not declared; mica-podman owns exactly what that file lists" >&2; \
        exit 1; \
    fi; \
    echo "podman-deb: the staged tree is exactly the $(wc -l < /tmp/declared) declared paths"

RUN set -eu; \
    pack.sh --root /stage --control /in/control/mica-podman.control \
            --version "${MICA_DEB_VERSION}" \
            --arch "${MICA_DEB_ARCH}" --out /out

# ONE ARCHIVE, AND IT IS mica-podman's. The other half of the independence claim:
# PACKAGES declares one package, so a producer that emitted a second archive
# would be one whose declaration and output had come apart -- and /out is what
# `-o type=local` copies into the shared pool, where a stray archive would be
# indexed by repo.sh as if some producer meant it.
RUN set -eu; \
    got="$(find /out -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"; \
    want="mica-podman_${MICA_DEB_VERSION}_${MICA_DEB_ARCH}.deb "; \
    [ "${got}" = "${want}" ] || { echo "error: this producer emits mica-podman and nothing else, and /out holds '${got}' rather than '${want}'" >&2; exit 1; }; \
    echo "podman-deb: /out holds ${want}and no other archive"

# The export stage, the shape pkgs/micad/deb/*/Dockerfile end in: `-o
# type=local` writes this stage's filesystem into _out/debs/<arch>/pool/ and
# nothing here installs into a root.
FROM scratch AS out
COPY --from=pack /out/ /

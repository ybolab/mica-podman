# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# The container engine, built from upstream source for aarch64.
#
#   make podman -> out/: podman, quadlet, crun, conmon, netavark,
#   aardvark-dns, catatonit, SHA256SUMS
#
# Same shape as boards/cx3576/bsp/kernel/Dockerfile: builder stages, then a final
# scratch stage that `-o` exports. Nothing here installs into a rootfs;
# rootfs/build.sh stages the output as it stages modules.tar and micad.

# The engine is built here for version control, not size: trixie ships podman
# 5.4.2, crun 1.21 and netavark 1.14, and building makes the version a
# decision recorded in versions.env rather than a consequence of which Debian
# release the base happens to be. Trimming the build (see BUILDTAGS) is a
# second, smaller benefit.

# Dynamic against glibc, not static against musl. Two hard blockers are
# musl-only: Rust edition 2024 needs rustc >= 1.85 and Alpine 3.21 shipped
# 1.83, and aardvark-dns 2.x calls libc::close_range, which the libc crate
# defines for gnu and NOT for musl (measured: 1 occurrence in gnu/mod.rs, 0 in
# musl/mod.rs), forcing a downgrade to the 1.17 network stack. Against glibc
# both go away and the 2.1 pair builds.

# The builders are trixie, matching the image's base: the binaries link
# against the same glibc, libseccomp and libsubid sonames the rootfs carries,
# so "it linked here" and "it runs there" are the same claim. The verify stage
# emits each binary's NEEDED list and rootfs/scripts/podman-assert.sh checks
# it with ldd against the assembled root. CGO is required: podman's Makefile
# says "Podman does not work w/o CGO_ENABLED, except in some very specific
# cases".

# Four builder stages, not one merged image, because one dependency list means
# one cache key for five unrelated compilers. Measured on this build: adding
# libsystemd-dev invalidated go-build and nothing else, so crun, conmon,
# catatonit, netavark and aardvark-dns all came from cache; merged behind one
# apt list the same one-package edit recompiles every component, about 42
# minutes under emulation. Separate stages also let BuildKit run C, Rust and
# Go concurrently, and the cache mounts below give the cheap re-provisioning a
# merge would be reaching for.

# The four shared builder images do not undo that. mos-build-{base,c,go,rust}
# is where the language toolchain comes from; each stage still keeps its own
# apt list holding exactly the -dev packages its own components need. The
# shared images carry compilers and no component's headers, and that boundary
# is what keeps them shared.

# The four builder images, injected from build-env/images.env by
# build-env/from.sh, which build.sh calls. Bare tags --
# debian:trixie-slim, golang:1.25-trixie, rust:1.90-trixie -- are repointed on
# upstream's own schedule, which leaves "which compiler built the engine on
# this device" answerable only from a build log. mos-build-go is Go 1.26.7 and
# mos-build-rust is Rust 1.98.0, both pinned by sha256 in images.env;
# README.md records what was checked under them beyond "it built".

# No defaults here, deliberately, and this is the one place in this file that
# differs from ELF_ARCH's reasoning below. Without a value docker refuses with
# "base name (${MOS_BUILD_BASE}) should not be blank" before any stage runs,
# which is a loud failure; a default would be exactly the unpinned float this
# pinning removes, and would build green against an image nobody chose.
# ELF_ARCH is defaulted so a bare `docker buildx build` still checks
# something. Build this through `make podman`.
ARG MOS_BUILD_BASE
ARG MOS_BUILD_C
ARG MOS_BUILD_GO
ARG MOS_BUILD_RUST

# Five arguments and four images, because one of the four is wanted at two
# architectures in the same build. Every stage below compiles for the TARGET
# and takes its base from MOS_BUILD_BASE, MOS_BUILD_C, MOS_BUILD_GO or
# MOS_BUILD_RUST; the src stage alone runs at the BUILD platform, because a
# `git clone` of six upstreams has no reason to run under emulation. Its base
# is therefore mos-build-base at the HOST's architecture, and that is a
# different image with a different name -- build-env/from.sh resolves a
# LOCAL_ key to a tag that CARRIES its architecture, so
# localhost/mos-build-base:amd64 and :arm64 coexist and neither is "the" base.
#
# It is a second ARGUMENT and not a second --platform because of what the
# single-architecture tag does when it is wrong, which is not to refuse.
# Measured on this host, both driver paths, a linux/arm64 build of this shape
# with the arm64 base resolved into the src stage:
#
#   #4 resolve localhost/mos-build-base:arm64@sha256:b1f5a46d... 0.0s done
#   #5 0.444 exec /bin/sh: exec format error
#
# `--platform=$BUILDPLATFORM` selects a manifest out of an index, and a
# `localhost/` tag is one manifest and no index -- so docker serves what the
# tag holds, buildkit believes the stage is running at the build platform, no
# emulator is applied, and the stage dies on its first RUN. Nothing in that
# report names the base, the architecture or the argument. The same is true of
# the OCI layout the docker-container driver is handed instead: a layout named
# after a tag holds that tag's one architecture, and buildx serves it rather
# than refusing the mismatch.
ARG MOS_BUILD_BASE_NATIVE

# Sources: fetched once, hashed, shared by every builder below.

# No apt-get here. This stage needs git and a CA bundle, two of the five
# packages mos-build-base exists to carry and asserts from inside itself
# (build-env/base/Dockerfile). Re-installing them would make that assertion
# decorative, and the first slimmed base would be found by a failed clone in a
# component build instead of by the image that claims the floor.
FROM --platform=$BUILDPLATFORM ${MOS_BUILD_BASE_NATIVE} AS src
# versions.lock, not versions.env: build.sh derives it by stripping comments
# and blank lines. The two carry identical values, and the lock is what this
# stage's cache key is computed over. Measured: adding a paragraph of prose to
# versions.env -- no version, no hash changed -- invalidated this COPY and
# every downstream stage, a two-hour recompile of crun, netavark, aardvark-dns
# and podman to record a rationale. A cache key should be the inputs, not the
# commentary about them, or the commentary stops getting written.
COPY versions.lock /versions.env

# Each fetch is a shallow clone at the pinned tag, verified against the hash
# in versions.env. `git archive` of the tag is a deterministic byte stream for
# the tree we compile, unlike a release tarball, which upstream can
# regenerate, and unlike a commit id, which says nothing about content. The
# hash covers the superproject tree only: a submodule appears in it as its
# commit id, so it is pinned transitively -- a git commit id is
# content-addressed -- but its bytes are not in this hash.

# --recurse-submodules is required: crun vendors libocispec as a submodule and
# a clone without it leaves an empty directory that ./configure only warns
# about and make then dies on ("No rule to make target 'all'"). .git is kept
# because crun and podman both read it to stamp a version, and deleting it
# trades a few MB in a stage that never ships for `fatal: not a git
# repository` in the middle of a compile.

# A PENDING pin prints the hash it computed and fails. There is deliberately
# no environment variable that softens it into a warning: a build that warns
# while versions.env says it fails teaches a reader to stop
# believing the documentation. A bump costs two runs instead of one, and buys
# that `git log` can never contain a commit whose engine came from an unhashed
# tag.
RUN --mount=type=cache,target=/root/.cache/git \
    set -eu; . /versions.env; \
    fetch() { \
        name="$1"; url="$2"; tag="$3"; want="$4"; \
        git clone --quiet --depth 1 --branch "${tag}" \
            --recurse-submodules --shallow-submodules "${url}" "/src/${name}"; \
        got="$(git -C "/src/${name}" archive --format=tar "${tag}" | sha256sum | cut -d' ' -f1)"; \
        if [ "${want}" = "PENDING" ]; then \
            echo "HASH ${name} ${tag} ${got}"; \
            echo "error: ${name} is pinned to ${tag} with no hash. Record the hash above against ${name} in versions.env and run again; until then this build would compile whatever the tag points at today, which is a different fact from the source this tree agreed to ship" >&2; exit 1; \
        elif [ "${want}" != "${got}" ]; then \
            echo "error: ${name} ${tag} hashes to ${got}, but versions.env pins ${want}. Either the tag was moved upstream or the pin is stale; do not paste the new hash in without finding out which" >&2; exit 1; \
        else \
            echo "ok ${name} ${tag} ${got}"; \
        fi; \
    }; \
    fetch podman       https://github.com/containers/podman.git       "${PODMAN_VERSION}"    "${PODMAN_SHA256}"; \
    fetch crun         https://github.com/containers/crun.git         "${CRUN_VERSION}"      "${CRUN_SHA256}"; \
    fetch conmon       https://github.com/containers/conmon.git       "${CONMON_VERSION}"    "${CONMON_SHA256}"; \
    fetch netavark     https://github.com/containers/netavark.git     "${NETAVARK_VERSION}"  "${NETAVARK_SHA256}"; \
    fetch aardvark-dns https://github.com/containers/aardvark-dns.git "${AARDVARK_VERSION}"  "${AARDVARK_SHA256}"; \
    fetch catatonit    https://github.com/openSUSE/catatonit.git      "${CATATONIT_VERSION}" "${CATATONIT_SHA256}"

# C components, running as aarch64 under the builder's emulation.
FROM ${MOS_BUILD_C} AS c-build
# The language toolchain came with the image; the components' headers did not,
# and that split is why mos-build-c is shared and this apt list still exists.
# build-essential, make, cmake, pkgconf, autoconf, automake, libtool, python3,
# ccache and file are facts about compiling C, so they live in mos-build-c,
# which asserts their versions from inside itself. The six -dev packages below
# are facts about crun, conmon and catatonit, and hoisting them into the
# shared image would put them in the cache key of every other component that
# stands on it -- the ~42-minute arithmetic in the note above.

# Grouped by what needs each package. A missing build tool reports as a
# missing command a hundred lines into a compile, which is how an earlier
# revision of this file spent an iteration on an absent autoconf.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-c,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-c,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        libseccomp-dev libcap-dev \
        libjson-c-dev libyajl-dev \
        libglib2.0-dev \
        libsystemd-dev
# CCACHE_DIR and the /usr/lib/ccache PATH entry are set by mos-build-c, not
# here; the mounts below are what make them worth setting. ccache in front of
# the real compilers gives the C components the compiled-object cache the Go
# stage has had since it was written (/root/.cache/go-build and /go/pkg/mod).
# Without it any change upstream of this stage pays a full crun recompile,
# ~10 minutes under emulation, to rebuild bytes identical to the previous
# run's. A cache directory is not a cache; the consumer's mount is.
COPY --from=src /src/crun /src/crun
COPY --from=src /src/conmon /src/conmon
COPY --from=src /src/catatonit /src/catatonit
RUN mkdir -p /out

# crun WITH systemd support, which is the difference between this binary
# working on the device and failing every container it is asked to start:
#
#   Error: OCI runtime error: crun: systemd not supported: Operation not supported
#
# This image is a systemd system and rootful podman's cgroup manager defaults
# to `systemd` (containers.conf.5, [engine] cgroup_manager: "systemd" is the
# default on systemd hosts), so crun is asked for a transient scope on the
# session bus at every `podman run`. A crun configured --disable-systemd
# compiles that path out and refuses at the moment a container starts.
#
# Nothing here reported it. The smoke tests exercise podman inside buildkit
# sandboxes where no systemd is running and podman falls back to the cgroupfs
# manager, so the systemd-cgroup path only exists on a booted device -- the
# same shape as the conmon journald finding below, found the same way.
#
# The dependency is free: libsystemd-dev is already installed in this stage
# for conmon, and crun's configure probes libsystemd with pkg-config and
# silently compiles the feature out when it is absent -- so the link check
# below is what makes the absence an error rather than a device-only surprise.
RUN --mount=type=cache,target=/ccache,id=ccache-c \
    set -eu; cd /src/crun; \
    ./autogen.sh; \
    ./configure; \
    make -j"$(nproc)"; \
    install -m0755 crun /out/crun; \
    ldd /out/crun | grep -q libsystemd || \
        { echo "error: crun linked no libsystemd. configure probes it with pkg-config and disables systemd support silently when it is missing; this binary would fail every podman run on the device with 'systemd not supported'" >&2; exit 1; }

# libsystemd-dev above is what gives conmon journald support, and its absence
# is not a build error: conmon's Makefile probes for libsystemd with
# pkg-config and simply compiles the journald path out when it is missing. The
# binary builds, installs and runs, and refuses only at the moment a container
# actually starts:
#   [conmon:e]: Include journald in compilation path to log to systemd journal
#   Error: conmon failed: exit status 1
# and /etc/containers/containers.conf sets log_driver = "journald", so that is
# every container on the device. Found by booting x64 and starting one.

# rootfs/scripts/podman-assert.sh already asserts libsystemd.so.0 is in the
# image because podman dlopens it for journald logging. That check is about
# podman and cannot see this: conmon's dependency is decided at compile time,
# in a different build, by whether a header was present.
RUN --mount=type=cache,target=/ccache,id=ccache-c \
    set -eu; cd /src/conmon; \
    make -j"$(nproc)" bin/conmon; \
    install -m0755 bin/conmon /out/conmon; \
    ldd /out/conmon | grep -q libsystemd || \
        { echo "error: conmon was built WITHOUT journald support. Its Makefile compiles the journald path out when libsystemd is not found, silently -- and containers.conf sets log_driver=journald, so every container start fails with 'Include journald in compilation path'" >&2; exit 1; }; \
    echo "conmon: linked against libsystemd, so log_driver=journald works"

# catatonit is static, alone among these, for a reason that is not about this
# image: it is copied into containers as their init, where the libc is
# whatever the container ships. A dynamic catatonit fails to exec inside
# anything not built against this glibc.
RUN --mount=type=cache,target=/ccache,id=ccache-c \
    set -eu; cd /src/catatonit; \
    ./autogen.sh && ./configure LDFLAGS="-static"; \
    make -j"$(nproc)"; \
    install -m0755 catatonit /out/catatonit

# Rust: netavark and aardvark-dns.

# mos-build-rust is Rust 1.98.0, from the tarball images.env pins by sha256.
# This stage does not run netavark's or aardvark-dns's test suites, so "it
# built" is the whole claim -- README.md records what was checked
# beyond that. protobuf-compiler and pkgconf stay here: netavark's build
# script runs protoc for its plugin API, which is a fact about netavark.
# ca-certificates is not in this list because mos-build-base carries and
# asserts it.
FROM ${MOS_BUILD_RUST} AS rust-build
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-rust,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-rust,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        protobuf-compiler pkgconf
COPY --from=src /src/netavark /src/netavark
COPY --from=src /src/aardvark-dns /src/aardvark-dns
# No --target and no crt-static: this is a native glibc build, so cargo's host
# and target are the same and nothing needs the host/target flag split the
# musl attempt required (crt-static in plain RUSTFLAGS reaches the host build
# too, and a proc-macro is a dynamic library that cannot be produced under it).

# The target/ mounts matter. With only the registry cached, cargo re-downloads
# nothing and recompiles everything: measured on this build, netavark 23m58s
# and aardvark-dns 8m05s, almost all of it the shared dependency tree, every
# time any stage above was invalidated. A cache mount is not part of the image
# layer, so it survives layer invalidation; that is safe here because cargo
# decides what to reuse by fingerprint, not by mtime, and a version bump in
# versions.env changes the source tree and cargo rebuilds what changed.
RUN --mount=type=cache,target=/usr/local/cargo/registry,id=cargo-registry \
    --mount=type=cache,target=/usr/local/cargo/git,id=cargo-git \
    --mount=type=cache,target=/src/netavark/target,id=netavark-target \
    --mount=type=cache,target=/src/aardvark-dns/target,id=aardvark-target \
    set -eu; mkdir -p /out; \
    cd /src/netavark && cargo build --release; \
    install -m0755 target/release/netavark /out/netavark; \
    cd /src/aardvark-dns && cargo build --release; \
    install -m0755 target/release/aardvark-dns /out/aardvark-dns

# Go: podman and its Quadlet generator.

# mos-build-go is Go 1.26.7, from the tarball images.env pins by sha256.
# build-essential is still installed here, and that is not an oversight:
# mos-build-go deliberately carries no C compiler. podman needs one because
# CGO_ENABLED is mandatory for it, but a cgo consumer needs its own -dev list
# anyway -- the four below -- so putting gcc in the shared Go image would give
# every pure-Go consumer a C toolchain in its cache key and still not spare
# this stage its apt line. git, ca-certificates and binutils are not in this
# list: mos-build-base carries all three and asserts them.
FROM ${MOS_BUILD_GO} AS go-build
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-go,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-go,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkgconf \
        libseccomp-dev libsubid-dev libsqlite3-dev libsystemd-dev
COPY --from=src /src/podman /src/podman

# BUILDTAGS is the trim, and each tag is a decision. containers_image_openpgp
# takes Go-native OpenPGP instead of libgpgme: Debian sets this tag for its
# podman-remote build and NOT for the local one, which is what drags the whole
# GnuPG suite -- gpg, gpg-agent, dirmngr, gpgsm, gnupg-l10n, libgcrypt, ~11 MB
# measured on trixie -- into the image for container-image signature
# verification this appliance does not do. exclude_graphdriver_btrfs and
# exclude_graphdriver_devicemapper: the storage driver is overlay
# (rootfs/overlay/etc/containers/storage.conf), devicemapper is
# deprecated upstream, and both keep libbtrfs and libdevmapper out of the link.

# Kept: seccomp, because on a root-mode engine the seccomp profile is the main
# thing between a container and the host kernel; systemd, which is how
# Quadlet-generated units integrate and which needs libsystemd-dev at build
# time for <systemd/sd-journal.h>; and libsubid, podman's uid/gid mapping.
# apparmor and selinux are NOT in the list, unlike Debian's build: neither is
# enforced in this image, and each adds a link dependency for a policy nothing
# loads.
ARG BUILDTAGS="seccomp systemd libsubid containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper"

# PREFIX=/usr, not the Makefile's default of /usr/local, and this is the kind
# of default that fails on the device and nowhere else. Makefile links
# `-X .../quadlet._binDir=$(BINDIR)` into the quadlet binary, and BINDIR
# defaults to ${PREFIX}/bin = /usr/local/bin, while mos installs podman at
# /usr/bin. With the default, quadlet parses a .container file correctly,
# generates a unit correctly, and writes an ExecStart pointing at a
# /usr/local/bin/podman that does not exist: nothing fails at build time, and
# the unit fails at start with "no such file or directory" naming podman.
# Debian passes the right PREFIX in its packaging; building ourselves means
# owning the flag.
ARG PODMAN_PREFIX=/usr
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    set -eu; cd /src/podman; mkdir -p /out; \
    make PREFIX="${PODMAN_PREFIX}" BUILDTAGS="${BUILDTAGS}" bin/podman bin/quadlet; \
    install -m0755 bin/podman /out/podman; \
    install -m0755 bin/quadlet /out/quadlet; \
    if strings -a bin/quadlet | grep -qx "/usr/local/bin"; then \
        echo "error: the quadlet binary still carries /usr/local/bin as its podman directory. Every unit it generates would name a podman that is not in this image, and the failure appears only when a container is started" >&2; exit 1; \
    fi

# Collect, and prove every artifact is what it claims to be.

# mos-build-base again, and this stage is why its floor names `file` and
# `binutils` rather than leaving them to whoever needs them: every assertion
# below is `file -b` reading an ELF header and `objdump -p` reading a NEEDED
# list. No apt-get, for the reason the src stage gives.
FROM ${MOS_BUILD_BASE} AS verify
# The architecture this build is FOR, so the assertion below cannot pass by
# naming the one it was first written against. Defaulted rather than required
# so a bare `docker buildx build` on this Dockerfile still checks something --
# unlike the four image arguments at the top, whose default would be the
# unpinned base this milestone exists to remove.
ARG ELF_ARCH=aarch64
COPY --from=c-build /out/ /out/
COPY --from=rust-build /out/ /out/
COPY --from=go-build /out/ /out/
# NEEDED.txt is EMITTED here, not checked here. Whether each soname resolves is
# a question about the image these binaries are going into, and it is asked in
# rootfs/scripts/podman-assert.sh with `ldd` against the assembled root -- the loader's
# own answer, rather than a list compared to a list from a previous build.
RUN set -eu; cd /out; \
    for b in podman quadlet crun conmon catatonit netavark aardvark-dns; do \
        test -f "$b" || { echo "error: $b was not produced by the build" >&2; exit 1; }; \
        file -b "$b" | grep -q "ELF 64-bit.*${ELF_ARCH}" || \
            { echo "error: $b is not an ${ELF_ARCH} ELF: $(file -b "$b")" >&2; exit 1; }; \
    done; \
    file -b catatonit | grep -q 'statically linked' || \
        { echo "error: catatonit is dynamically linked. It is copied INTO containers as their init and must not depend on this image's libc" >&2; exit 1; }; \
    for b in podman quadlet crun conmon netavark aardvark-dns; do \
        objdump -p "$b" | awk -v b="$b" '/NEEDED/{print b": "$2}'; \
    done > /out/NEEDED.txt; \
    for b in podman quadlet crun conmon catatonit netavark aardvark-dns; do \
        printf '%-16s %8s KiB  %s\n' "$b" "$(( $(stat -c%s "$b") / 1024 ))" "$(file -b "$b" | cut -c1-38)"; \
    done; \
    sha256sum podman quadlet crun conmon catatonit netavark aardvark-dns > /out/SHA256SUMS

FROM scratch AS artifact
COPY --from=verify /out/ /

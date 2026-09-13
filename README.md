# mica-podman — the container engine of Mica OS, built from source

This repository produces seven binaries for `MOS_ARCH` (arm64 by default)
into `out-<arch>/` and packs them, with the container configuration under
`overlay/`, as the Debian package `mica-podman`. It stands on the
`mica-build-env` substrate, fetched at its pin into `build-env/`:

```
make deps            # build-env/ at deps/sources/mica-build-env.json
make build-env       # the builder images
MOS_ARCH=arm64 make podman   # -> out-arm64/
make pool            # both archives into _out/debs/<arch>/pool, indexed
make package-gate    # the gate over that pool
make publish         # the release build-<commit12> of this commit
```

The assembly (`ybolab/mica-build`) imports the archives through
`deps/packages/mica-podman.json` (`make os-lock-bump COMPONENT=mica-podman`
there) and never builds them itself.

`build.sh` is builder stages, then a `FROM scratch AS artifact` that `-o`
exports. The output directory follows the architecture so an arm64 and an
amd64 set can coexist.

| Binary | What it is |
|---|---|
| `podman` | the engine. Daemonless: `podman run` forks `conmon`, which execs `crun` |
| `quadlet` | the systemd generator that turns a `.container` file into a service |
| `crun` | the OCI runtime. C, not Go — and what trixie's podman already invokes |
| `conmon` | per-container monitor |
| `netavark` | networking |
| `aardvark-dns` | container-to-container name resolution |
| `catatonit` | container init, for `--init` |

The `podman` producer (`deb/podman/`) takes the set from here and packs it as
`mica-podman`; the rootfs composition installs that package out of
`_out/debs/<arch>/` and never sees this directory. The producer's `PREPARE`
hook will build the seven binaries itself if they are absent, which is roughly
three quarters of an hour inside a packaging hook -- `make os-deb-preflight`
says so before `os-debs` starts, and `MOS_ARCH=<arch> make podman` is how to
pay that cost where it can be seen.

## Bumping a version

`versions.env` is the only file to edit. Set the tag, set its hash to the
literal `PENDING`, and run `make podman`: the build prints the hash it
computed and **fails**. Paste that in and run again.

The two-step is deliberate. It makes recording a hash an act, rather than a
value copied from an upstream page that nobody re-checked. There is no
warn-only mode and no environment variable that relaxes it, so the developer
path and the release path are the same path.

The hash is over `git archive` of the tag, so it covers the tree that is
actually compiled. A tag can be moved upstream; a tree hash cannot.

## Which compiler builds it

The four builder stages stand on `localhost/mos-build-{base,c,go,rust}`, built
by `make build-env` from `build-env/images.env` — a digest-pinned floor
rather than three upstream tags that are repointed on someone else's schedule.
Each binary is proven under that toolchain rather than merely rebuilt, on
amd64:

| binary | built by | reported version | `versions.env` pins |
| --- | --- | --- | --- |
| podman | `go1.26.7` (from `go version -m`) | 5.8.6 | `v5.8.6` |
| quadlet | `go1.26.7` | 5.8.6 | (podman's tree) |
| crun | GCC (Debian 14.2.0-19) | 1.29.1 | `1.29.1` |
| conmon | GCC (Debian 14.2.0-19) | 2.2.1 | `v2.2.1` |
| catatonit | GCC (Debian 14.2.0-19) | 0.2.1 | `v0.2.1` |
| netavark | rustc `88d9e12ae178…` = 1.98.0 | 2.1.0 | `v2.1.0` |
| aardvark-dns | rustc `88d9e12ae178…` = 1.98.0 | 2.1.0 | `v2.1.0` |

"Built by" is read out of each artefact, not assumed from the image. Each
binary is then executed, in the digest-pinned trixie with the sonames
`NEEDED.txt` names installed — not the builder image, which carries the `-dev`
headers and not the runtime libraries. `podman info` (privileged, because it
re-execs into a user namespace) resolves this build's own conmon and crun and
reports `netavark 2.1.0` as its network backend, with `+SECCOMP +JSON_C` —
which is the `-dev` list below doing its job.

The `-dev` packages stay in this Dockerfile and are deliberately **not** in
`mos-build-c`. libseccomp, libcap, libjson-c, libyajl, glib and libsystemd are
facts about crun, conmon and catatonit; hoisting them into the shared image
would put them in the cache key of every other component that stands on it,
which is the ~42-minute measurement recorded at the top of the Dockerfile. For
the same reason `mos-build-go` carries no C compiler and the Go stage installs
`build-essential` itself.

Building for **arm64 needs an arm64 builder family**, because a `localhost/` tag
carries exactly one architecture where a `name:tag@sha256:` digest is a
multi-architecture index. `build.sh` refuses the mismatch by name.

### Two bases, and why there are five arguments for four images

A cross build needs **both** families on the host, not just the target's. The
Dockerfile takes five base arguments:

| argument | architecture | which stages |
| --- | --- | --- |
| `MOS_BUILD_BASE` | the target's, `MOS_ARCH` | `verify` |
| `MOS_BUILD_C` | the target's | `c-build` |
| `MOS_BUILD_GO` | the target's | `go-build` |
| `MOS_BUILD_RUST` | the target's | `rust-build` |
| `MOS_BUILD_BASE_NATIVE` | the **host's**, `uname -m` | `src` |

`src` is the odd one because it is the one stage that does not compile: it
shallow-clones six upstreams and hashes them, and `FROM --platform=$BUILDPLATFORM`
keeps that out of emulation. Its base is therefore `mos-build-base` at the
architecture buildkit itself runs on, which under the architecture-qualified
tag scheme is a different image with a different name — `:amd64` and `:arm64`
coexist and neither is "the" base. `build.sh` resolves it through a second
`build-env/from.sh` call with `--arch` set from `uname -m`, and hands the
`mos-*` docker-container builder a second OCI layout for it, next to the four
it already exports. On a native build the two resolve to the same tag and no
fifth layout is exported.

It has to be a second **argument**, because a single-architecture tag handed to
`--platform=$BUILDPLATFORM` does not refuse — `--platform` selects a manifest
out of an index, and a `localhost/` tag is one manifest and no index. Docker
serves what the tag holds, buildkit believes the stage is running at the build
platform, no emulator is applied, and the stage dies on its first `RUN` with
`exec /bin/sh: exec format error` — a report that names neither the base, the
architecture, nor the argument. The same is true of the OCI layout the
docker-container driver gets instead. Measured on both driver paths; the arm64
target's build for the amd64 host is what stopped on it.

Practically: `MOS_ARCH=arm64 make podman` on an amd64 host needs
`MOS_BUILD_PLATFORM=linux/arm64 make build-env` **and** the amd64 family from a
plain `make build-env`. `build.sh` names the missing one and the command that
makes it.

## Why build it, when trixie ships a working one

Not to save space, and not because the package is missing a feature. What this
directory buys is version autonomy:

| | trixie (apt) | this directory |
|---|---|---|
| podman | 5.4.2 | 5.8.6 |
| crun | 1.21 | 1.29.1 |
| netavark | 1.14 | 2.1.0 |
| aardvark-dns | 1.14 | 2.1.0 |

The gap is not the point — it will be different next month. The point is that
the version becomes a line in `versions.env` instead of a consequence of which
Debian the base happens to be. Independence is bought per component, not per
distribution: nothing here obliges the other 500-odd packages in the image to
leave apt.

## Why the binaries are dynamically linked

- **The image already has glibc.** Static linking against musl buys
  independence from a libc that ships either way, at the cost of a second
  toolchain.
- **Two hard blockers are musl-only.** `close_range` is absent from the musl
  side of the `libc` crate (measured: 1 occurrence under `gnu`, 0 under `musl`)
  and crun's autotools path needs reworking there.

`catatonit` is static, for a reason that applies to it alone: it is copied
*into* containers as their init, so it must not depend on this image's libc.

The verify stage asserts each of those separately — seven ELFs of the target
architecture, `catatonit` statically linked, and for every other binary, each
`NEEDED` soname present in `image-libs.txt`. That last list is **generated from
the packed rootfs**, never hand-written: a hand-kept list keeps passing after
the image drops a package, and the binary that needed it fails on the device
instead. crun 1.29.1 needs `libjson-c.so.5` where trixie's 1.21 needs
`libyajl.so.2` — upstream deleted yajl between them — and only a generated list
follows that.

## What this costs, stated plainly

Six upstreams to track for CVEs, in three languages. On the packaged path
Debian's security team does that work; here it is ours. `versions.env` plus a
scheduled upstream-tag check in the privileged CI lane is the
mitigation, and it is not optional — a pinned version with nothing watching it
is a version that silently rots.

`catatonit` is the one to watch: its newest release is v0.2.1 (2024-12-14). A
container init is small and rarely needs to change, so a quiet upstream is not
by itself alarming — but it is the component where "no new tag" and "abandoned" look
identical, and the M5 check cannot tell them apart.

## What watches the pins

`make podman-pins` reads `versions.env`, asks each of the six upstreams for its
releases, and goes red when a pin is behind. `check-pins.sh` is the whole of it.
It is the mitigation the section above calls not optional, and it closes
The pin check runs on its own schedule.

**It reads the file and never writes it.** No bump, no pull request, no
`versions.env` edit. Moving a pin costs a tag, a hash set to `PENDING` and a
`make podman`; this file already says recording a hash "is an act rather than a
copy from an upstream page nobody re-checked", and a robot that pasted the new
tag in would be exactly that copy. The output of a red run is a sentence naming
the component, its pin, the newer tag and that procedure.

Three things the comparison has to get right, and each is a fixture case in
`tests/podman-pins-test.sh` rather than an assumption:

- **The six do not share a tag convention.** crun tags `1.29.1`; the other five
  tag `v2.1.0`. The prefix is taken from the pin as written rather than
  normalised to a guess, so a tag from the other namespace is skipped *and
  counted in the output*. A component where nothing upstream matches the pin's
  convention fails the run — comparing nothing is not a pass.
- **podman is on the 5.x line on purpose.** Upstream ships v5.8.6 and v6.1.0
  concurrently. The comparison is confined to the pinned major, taken from the
  pin itself, so a correct pin is never reported behind and moving the pin to
  6.x moves the check with it without an edit here. The other line is printed as
  a note that cannot change the exit status: which line to be on is
  `versions.env`'s decision.
- **catatonit is quiet, not abandoned.** Age is never an input to the verdict;
  the only question is whether a newer comparable tag exists. The date is
  printed so a quiet upstream reads as measured. The suite asserts both
  directions — green while upstream is quiet, red against a recorded response in
  which v0.3.0 shipped — because "correctly pinned" and "never actually
  compared" otherwise produce the same green.

It runs weekly in the privileged lane
(`.github/workflows/privileged.yml`), on that file's existing cron rather than
a second one. The fast lane has no network. `make podman-pins-test` needs none:
`--releases-dir` and `--versions-env` choose where the two inputs come from, so
every branch above runs against upstream responses recorded in
`tests/podman-pins/` — and proving that a backwards pin turns the run red
never requires writing to the real pin file.

# mica-podman

The container engine of Mica OS, built from pinned upstream source and packed
as the Debian package `mica-podman`, the only output of this repository. It
builds on the mica-build-env release pinned in `build-env.env` (version and
the sha256 of its `SHA256SUMS`) and the `IMAGE_MICA_BUILD_*` images that
release names, and implements the release's `RULES.md` in its own scripts.

```
make build-env                # _out/build-env/v<version>/, verified
MICA_ARCH=arm64 make podman   # -> _out/podman/arm64/
make pool                     # -> _out/debs/{amd64,arm64}/mica-podman_*.deb
make package-gate             # the gate, with no-cache rebuilds
make check                    # offline checks
```

| Binary | Role |
|---|---|
| `podman` | the engine; `docker` is an alias |
| `quadlet` | systemd generator for `.container` files |
| `crun` | OCI runtime |
| `conmon` | per-container monitor |
| `netavark` | networking |
| `aardvark-dns` | container name resolution |
| `catatonit` | container init (static) |

The package also carries `/etc/containers` (storage and network state under
`/mica/containers`) and `etc-containers-systemd.mount`, which mica-core
enables from the `container.enabled` setting.

| Path | Role |
|---|---|
| `build.sh`, `Dockerfile` | the engine binaries |
| `tools/package.sh`, `deb/` | the archive: staging, payload manifest, `pack.sh` |
| `tests/package-gate.sh` | identity, payload, copyright, no conffiles or enablement, reproducibility |
| `tools/release.sh` | the GitHub Release: identity checks, never replaced, anonymous download |
| `tools/build-env.sh` | release download and verification |

## CI and releases

`ci.yml` builds, packs and gates both architectures on every push to main and
pull request, and publishes nothing. Releasing is manual, as in mica-build-env:

```
gh workflow run release.yml -R ybolab/mica-podman --ref main
```

`release.yml` builds and gates the head of main again, then `tools/release.sh`
creates the GitHub Release `<YYYYMMDD-HHMM>` (UTC, the time of the release)
tagged at that commit, with `mica-podman_<version>_<arch>.deb` (`+` written
`.`) for amd64 and arm64 and `SHA256SUMS`, and downloads it back with no
credential. It refuses a commit not on main, a name that exists or is not
after the newest release, and a commit that is already released; a release is
never changed.

## Bumping a version

Edit `versions.env`: set the tag, set its hash to `PENDING`, run
`make podman`, paste the printed `git archive` tree hash and run again.
`_out/podman/<arch>/VERSIONS.env` records which pins a build used; packaging
refuses a stale directory. `make podman-pins` (weekly in CI) reports pins that
have a newer upstream release; it never edits `versions.env`.

A new mica-build-env release is adopted by changing both values in
`build-env.env`.

## Building

`build.sh` and `tools/package.sh` use the `default` buildx builder when it
offers the target platform, else the `mica-<arch>` docker-container builder,
which emulates the other architecture. CI builds each architecture on a native
runner. The binaries link glibc dynamically; `catatonit` is static because it
runs inside containers.

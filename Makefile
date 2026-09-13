# mica-podman: the container engine of Mica OS, built from source and packed
# as the Debian package mica-podman. Heavy lifting stays in the scripts; this
# file only routes.

# THE SOURCE DEPENDENCY, before anything else: build-env/ (mica-build-env) is
# the substrate every target reaches through. It is fetched at its pin
# (deps/sources/mica-build-env.json) by tools/deps.sh and is gitignored, so a
# fresh clone has none, and every target would then fail somewhere deep with
# a message naming a file instead of the cause. `make deps` is the one target
# that may run without it.
ifeq ($(filter deps,$(MAKECMDGOALS)),)
ifeq ($(wildcard build-env/from.sh),)
$(error build-env/ is empty: the build substrate is fetched at its pin from ybolab/mica-build-env. Run: make deps)
endif
endif

MICA_ARCH ?= arm64

.PHONY: help deps deps-check deps-bump build-env podman podman-pins podman-pins-test deb-preflight-test deb pool publish package-gate preflight lint check

help:
	@echo "  deps                fetch build-env/ at its pin (deps/sources/); deps-check reads without downloading"
	@echo "  deps-bump           rewrite the pin from the newest build-* release (DEP_TAG=build-<commit12> picks one)"
	@echo "  build-env           the builder images, from the pins in build-env/images.env"
	@echo "  podman              build the seven engine binaries into out-\$$MICA_ARCH (MICA_ARCH=amd64|arm64)"
	@echo "  podman-pins         are the upstream tags in versions.env current? (network)"
	@echo "  podman-pins-test    the check on that check, against recorded upstream responses (offline)"
	@echo "  deb                 pack out-\$$MICA_ARCH as mica-podman into _out/debs/\$$MICA_ARCH/pool"
	@echo "  pool                both architectures, indexed (Packages, SHA256SUMS, manifest.txt)"
	@echo "  package-gate        the package gate over this repository's pool"
	@echo "  publish             the pool as the GitHub Release build-<commit12> of this commit"
	@echo "  lint                shell hygiene of the tree"
	@echo "  check               everything that runs offline: lint, podman-pins-test, deb-preflight-test, preflight"

deps:
	bash tools/deps.sh fetch
deps-check:
	bash tools/deps.sh fetch --check
deps-bump:
	bash tools/deps.sh bump mica-build-env $(if $(DEP_TAG),--tag "$(DEP_TAG)")

build-env:
	bash build-env/build.sh

podman:
	bash build.sh

podman-pins:
	bash check-pins.sh

podman-pins-test:
	bash tests/podman-pins-test.sh

# The versions stamp and the producer's pre-flight against a fixture out-<arch>
# (offline; needs `file` and a host ELF of this architecture).
deb-preflight-test:
	bash tests/deb-preflight-test.sh

# The producer's PREPARE hook answers, without building, whether out-<arch>
# is present, complete and stamped by the current versions.env.
preflight:
	bash build-env/deb/preflight.sh

deb: preflight
	bash build-env/deb/build.sh --producer podman --arch $(MICA_ARCH)

pool: preflight
	bash build-env/deb/build.sh --producer podman --arch amd64
	bash build-env/deb/build.sh --producer podman --arch arm64
	bash build-env/deb/repo.sh --arch amd64
	bash build-env/deb/repo.sh --arch arm64

package-gate:
	bash build-env/deb/package-gate.sh

publish:
	bash build-env/deb/publish.sh

lint:
	bash tests/shell-lint.sh

check: lint podman-pins-test deb-preflight-test preflight

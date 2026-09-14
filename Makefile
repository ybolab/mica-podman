# mica-podman: the container engine of Mica OS as the Debian package mica-podman.

MICA_ARCH ?= arm64

.PHONY: help build-env podman podman-pins podman-pins-test stamp-test build-env-test package-test release-test deb pool package-gate publish lint check

help:
	@echo "  build-env           fetch and verify the pinned mica-build-env release (build-env.env)"
	@echo "  podman              build the seven engine binaries into _out/podman/\$$MICA_ARCH (MICA_ARCH=amd64|arm64)"
	@echo "  deb                 pack _out/podman/\$$MICA_ARCH into _out/debs/\$$MICA_ARCH/"
	@echo "  pool                deb for amd64 and arm64"
	@echo "  package-gate        the package gate over _out/debs, with no-cache rebuilds"
	@echo "  publish             release _out/debs as the GitHub Release <YYYYMMDD-HHMM> (release workflow only)"
	@echo "  podman-pins         are the upstream tags in versions.env current? (network)"
	@echo "  check               lint, podman-pins-test, stamp-test, build-env-test, package-test, release-test"

build-env:
	bash tools/build-env.sh fetch

podman:
	bash build.sh

deb:
	bash tools/package.sh --arch $(MICA_ARCH)

pool:
	bash tools/package.sh --arch amd64
	bash tools/package.sh --arch arm64

package-gate:
	bash tests/package-gate.sh --reproduce

publish:
	bash tools/release.sh

podman-pins:
	bash check-pins.sh

podman-pins-test:
	bash tests/podman-pins-test.sh

stamp-test:
	bash tests/stamp-test.sh

build-env-test:
	bash tests/build-env-test.sh

package-test:
	bash tests/package-test.sh

release-test:
	bash tests/release-test.sh

lint:
	bash tests/shell-lint.sh

check: lint podman-pins-test stamp-test build-env-test package-test release-test

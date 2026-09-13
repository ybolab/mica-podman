#!/usr/bin/env bash
# Carry the archives of an existing GitHub Release into this repository's
# pool artifacts, byte for byte.
#
#   bash tools/transport-pool.sh --revision <40 hex> --expect-amd64 <64 hex> --expect-arm64 <64 hex>
#
#   reads   the release build-<commit12> of ybolab/mica-podman (gh, GH_TOKEN)
#   writes  <registry>/mica-podman:pool.<arch>.build-<commit12>, through the
#           pinned substrate's build-env/deb/publish.sh run in a worktree of
#           <revision>, so the artifact names that commit and its date
#
# The release predates per-repository packages; consumers already pin those
# archives by sha256, so nothing is rebuilt. Before any registry access each
# archive must hash to the digest given for its architecture and carry the
# control identity of <revision> (Package mica-podman, its Architecture,
# Mica-Source-Repo mica-podman, Mica-Source-Commit <revision>); a mismatch
# publishes nothing. The layer is titled <Package>_<Version>_<Architecture>.deb,
# the name the pool build gives it, not the `.`-for-`+` release asset name.
# Publishing is CI's (.github/workflows/transport-pool.yml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
REPOSITORY=mica-podman
ARCHES=(amd64 arm64)

die() { echo "transport-pool.sh: error: $*" >&2; exit 1; }
usage() { die "usage: bash tools/transport-pool.sh --revision <40 hex> --expect-amd64 <64 hex> --expect-arm64 <64 hex>"; }

REVISION=""
declare -A EXPECT=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --revision) [ "$#" -ge 2 ] || usage; REVISION="$2"; shift 2 ;;
    --expect-amd64) [ "$#" -ge 2 ] || usage; EXPECT[amd64]="$2"; shift 2 ;;
    --expect-arm64) [ "$#" -ge 2 ] || usage; EXPECT[arm64]="$2"; shift 2 ;;
    *) usage ;;
    esac
done
[[ "${REVISION}" =~ ^[0-9a-f]{40}$ ]] || die "--revision takes a full 40-hex commit, not '${REVISION}'"
for a in "${ARCHES[@]}"; do
    [[ "${EXPECT[${a}]:-}" =~ ^[0-9a-f]{64}$ ]] || die "--expect-${a} takes the 64-hex sha256 consumers pin, not '${EXPECT[${a}]:-}'"
done
for t in gh git python3 sha256sum; do
    command -v "${t}" >/dev/null 2>&1 || die "${t} is required and not on PATH"
done
PUBLISH="${REPO_ROOT}/build-env/deb/publish.sh"
FIELDS="${REPO_ROOT}/build-env/deb/control-fields.py"
[ -f "${PUBLISH}" ] && [ -f "${FIELDS}" ] || die "build-env/ carries no deb/publish.sh; fetch the substrate at its pin first (make deps)"
git -C "${REPO_ROOT}" cat-file -e "${REVISION}^{commit}" 2>/dev/null && git -C "${REPO_ROOT}" merge-base --is-ancestor "${REVISION}" HEAD ||
    die "${REVISION} is not a commit in the history of HEAD"

TAG="build-${REVISION:0:12}"
WORK="$(mktemp -d)"
SRC="${WORK}/src"
cleanup() {
    [ ! -d "${SRC}" ] || git -C "${REPO_ROOT}" worktree remove --force "${SRC}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

gh release download "${TAG}" -R "ybolab/${REPOSITORY}" -D "${WORK}/release" -p "${REPOSITORY}_*.deb" ||
    die "downloading the archives of the release ${TAG} of ybolab/${REPOSITORY} failed"

# Refusals first, so a run publishes all or nothing.
for a in "${ARCHES[@]}"; do
    mapfile -t found < <(find "${WORK}/release" -maxdepth 1 -type f -name "${REPOSITORY}_*_${a}.deb" | LC_ALL=C sort)
    [ "${#found[@]}" -eq 1 ] || die "the release ${TAG} carries ${#found[@]} ${a} archive(s) of ${REPOSITORY}, not one"
    deb="${found[0]}"
    sha="$(sha256sum "${deb}" | cut -d' ' -f1)"
    [ "${sha}" = "${EXPECT[${a}]}" ] || die "$(basename "${deb}") of ${TAG} hashes to ${sha}, and consumers pin ${EXPECT[${a}]}; nothing was published"
    mapfile -t got < <(python3 "${FIELDS}" "${deb}" Package Version Architecture Mica-Source-Repo Mica-Source-Commit)
    [ "${got[0]:-}" = "${REPOSITORY}" ] && [ "${got[2]:-}" = "${a}" ] && [ "${got[3]:-}" = "${REPOSITORY}" ] && [ "${got[4]:-}" = "${REVISION}" ] &&
        [[ "${got[1]:-}" =~ \+git${REVISION:0:12}-[1-9][0-9]*$ ]] ||
        die "$(basename "${deb}") carries Package '${got[0]:-}', Version '${got[1]:-}', Architecture '${got[2]:-}', Mica-Source-Repo '${got[3]:-}', Mica-Source-Commit '${got[4]:-}', not the ${a} archive of ${REPOSITORY} at ${REVISION}; nothing was published"
    mkdir -p "${WORK}/pool/${a}/pool"
    cp "${deb}" "${WORK}/pool/${a}/pool/${got[0]}_${got[1]}_${got[2]}.deb"
done

# publish.sh publishes the checkout it lives in: a worktree of the revision,
# with the pinned substrate beside it (build-env/ is gitignored there too).
git -C "${REPO_ROOT}" worktree add --detach "${SRC}" "${REVISION}" >/dev/null
cp -a "${REPO_ROOT}/build-env" "${SRC}/build-env"

# Each architecture is attempted even when the other fails, so one run
# uploads both; the job is red if either is.
rc=0
for a in "${ARCHES[@]}"; do
    bash "${SRC}/build-env/deb/publish.sh" --pool "${WORK}/pool" --arch "${a}" || rc=1
done
exit "${rc}"

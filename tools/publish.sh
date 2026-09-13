#!/usr/bin/env bash
# Publish _out/debs/{amd64,arm64} of a clean HEAD as the pool artifacts
# <registry>/<repository>:pool.<arch>.build-<commit12> (RULES.md section 3).
#
#   GH_TOKEN=<token with write:packages> MICA_REGISTRY_USER=<user> bash tools/publish.sh
#
# Every archive is checked before any registry access. An existing tag must
# already hold exactly these bytes and this identity; it is never re-pointed.
# Both pools are uploaded, then each manifest and deb is read back with no
# credential, which fails while the package is private. The token is never printed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE=mica-podman
ARCHES=(amd64 arm64)
MANIFEST_TYPE=application/vnd.oci.image.manifest.v1+json
EMPTY_DIGEST=sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a

die() { echo "publish.sh: error: $*" >&2; exit 1; }
for t in curl jq sha256sum dpkg-deb git base64; do
    command -v "${t}" >/dev/null 2>&1 || die "${t} is required and not on PATH"
done

REGISTRY="${MICA_REGISTRY:-ghcr.io/ybolab}"
[[ "${REGISTRY}" =~ ^([A-Za-z0-9.-]+(:[0-9]+)?)/([a-z0-9][a-z0-9-]*)$ ]] || die "MICA_REGISTRY '${REGISTRY}' is not <host>/<owner>"
HOST="${BASH_REMATCH[1]}"
OWNER="${BASH_REMATCH[3]}"
if [ "${MICA_REGISTRY_PLAIN_HTTP:-0}" = 1 ]; then
    [[ "${HOST}" == *:* ]] || die "MICA_REGISTRY_PLAIN_HTTP=1 is for a local test registry with a port"
    BASE="http://${HOST}"
else
    BASE="https://${HOST}"
fi

# ---- identity, before any registry access
cd "${REPO_ROOT}"
[ -z "$(git status --porcelain)" ] || die "the checkout has uncommitted changes; only a clean HEAD is published"
COMMIT="$(git rev-parse HEAD)"
C12="${COMMIT:0:12}"
REPOSITORY="$(basename "$(git remote get-url origin)" .git)"
[[ "${REPOSITORY}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "origin '${REPOSITORY}' is not a package name"
CREATED="$(date -u -d "@$(git show -s --format=%ct HEAD)" +%Y-%m-%dT%H:%M:%SZ)"
ARTIFACT="${OWNER}/${REPOSITORY}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
printf '{}' >"${WORK}/config"

VERSION=""
for arch in "${ARCHES[@]}"; do
    dir="_out/debs/${arch}"
    mapfile -t debs < <(find "${dir}" -maxdepth 1 -type f -name '*.deb' 2>/dev/null | LC_ALL=C sort)
    [ "${#debs[@]}" -eq 1 ] || die "${dir} holds ${#debs[@]} archives; exactly one ${PACKAGE} archive is published per architecture"
    deb="${debs[0]}"
    field() { dpkg-deb --field "${deb}" "$1"; }
    [ "$(field Package)" = "${PACKAGE}" ] || die "${deb} is Package $(field Package), not ${PACKAGE}"
    [ "$(field Architecture)" = "${arch}" ] || die "${deb} is Architecture $(field Architecture), not ${arch}"
    [ "$(field Mica-Source-Repo)" = "${REPOSITORY}" ] || die "${deb} carries Mica-Source-Repo $(field Mica-Source-Repo), not ${REPOSITORY}"
    [ "$(field Mica-Source-Commit)" = "${COMMIT}" ] || die "${deb} carries Mica-Source-Commit $(field Mica-Source-Commit), not HEAD ${COMMIT}"
    v="$(field Version)"
    [[ "${v}" =~ ^[0-9][0-9.]*\+git${C12}-1$ ]] || die "${deb} Version ${v} is not <upstream>+git${C12}-1"
    [ -z "${VERSION}" ] || [ "${v}" = "${VERSION}" ] || die "${deb} Version ${v} differs from ${VERSION}; one stamp per publication"
    VERSION="${v}"
    title="${PACKAGE}_${v}_${arch}.deb"
    [ "$(basename "${deb}")" = "${title}" ] || die "${deb} is not named ${title}"
    cp "${deb}" "${WORK}/${arch}.deb"
    jq -jcn --arg arch "${arch}" --arg digest "sha256:$(sha256sum "${deb}" | cut -d' ' -f1)" --argjson size "$(stat -c %s "${deb}")" \
        --arg title "${title}" --arg commit "${COMMIT}" --arg created "${CREATED}" --arg repo "${REPOSITORY}" \
        --arg source "https://github.com/${OWNER}/${REPOSITORY}" --arg empty "${EMPTY_DIGEST}" '{
            schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: "application/vnd.mica.pool",
            config: {mediaType: "application/vnd.oci.empty.v1+json", digest: $empty, size: 2},
            layers: [{mediaType: "application/vnd.mica.deb", digest: $digest, size: $size, annotations: {"org.opencontainers.image.title": $title}}],
            annotations: {"org.opencontainers.image.revision": $commit, "org.opencontainers.image.created": $created,
                "org.opencontainers.image.source": $source, "mica.source-repo": $repo, "mica.source-commit": $commit, "mica.arch": $arch}}' \
        >"${WORK}/${arch}.manifest"
done

[ -n "${GH_TOKEN:-}" ] && [ -n "${MICA_REGISTRY_USER:-}" ] || die "GH_TOKEN and MICA_REGISTRY_USER must be set; publishing is CI's, with its own token"

# ---- registry client
# auth <pull|pull,push> <anon|cred>: writes ${WORK}/hdr; prints the token endpoint status on failure.
auth() {
    local actions="$1" mode="$2" challenge realm service code token
    : >"${WORK}/hdr"
    chmod 600 "${WORK}/hdr"
    challenge="$(curl -sS --max-time 60 -o /dev/null -D - "${BASE}/v2/${ARTIFACT}/tags/list" 2>/dev/null | tr -d '\r' | grep -i '^www-authenticate:' || true)"
    case "$(printf '%s' "${challenge}" | tr '[:upper:]' '[:lower:]')" in
    "") return 0 ;;
    *basic*)
        [ "${mode}" = anon ] || printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "${MICA_REGISTRY_USER}" "${GH_TOKEN}" | base64 -w0)" >"${WORK}/hdr"
        return 0
        ;;
    esac
    realm="$(printf '%s' "${challenge}" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
    service="$(printf '%s' "${challenge}" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
    code="$(curl -sS --max-time 60 -o "${WORK}/token.json" -w '%{http_code}' \
        --config <([ "${mode}" = anon ] || printf 'user = "%s:%s"\n' "${MICA_REGISTRY_USER}" "${GH_TOKEN}") \
        --get --data-urlencode "service=${service}" --data-urlencode "scope=repository:${ARTIFACT}:${actions}" "${realm}" 2>/dev/null || echo 000)"
    token="$(jq -r '.token // .access_token // empty' "${WORK}/token.json" 2>/dev/null || true)"
    rm -f "${WORK}/token.json"
    [ "${code}" = 200 ] && [ -n "${token}" ] || { echo "${code}"; return 1; }
    printf 'Authorization: Bearer %s\n' "${token}" >"${WORK}/hdr"
}
req() { # <method> <path under v2/<artifact>/> <out> [curl args] -> status
    local method="$1" path="$2" out="$3"
    shift 3
    curl -sS --max-time 1800 -o "${out}" -w '%{http_code}' -X "${method}" -H @"${WORK}/hdr" "$@" "${BASE}/v2/${ARTIFACT}/${path}" 2>/dev/null || echo 000
}
blob_put() { # <file>
    local file="$1" digest status location
    digest="sha256:$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "$(curl -sS --max-time 60 -o /dev/null -w '%{http_code}' -I -H @"${WORK}/hdr" "${BASE}/v2/${ARTIFACT}/blobs/${digest}" 2>/dev/null || echo 000)" != 200 ] || return 0
    status="$(req POST blobs/uploads/ /dev/null -D "${WORK}/upload.h" -H 'Content-Length: 0')"
    [ "${status}" = 202 ] || die "starting an upload to ${HOST}/${ARTIFACT} answered HTTP ${status}"
    location="$(tr -d '\r' <"${WORK}/upload.h" | sed -n 's/^[Ll]ocation: //p' | head -n1)"
    case "${location}" in /*) location="${BASE}${location}" ;; esac
    case "${location}" in *\?*) location="${location}&digest=${digest}" ;; *) location="${location}?digest=${digest}" ;; esac
    status="$(curl -sS --max-time 1800 -o /dev/null -w '%{http_code}' -X PUT -H @"${WORK}/hdr" -H 'Content-Type: application/octet-stream' \
        --data-binary @"${file}" "${location}" 2>/dev/null || echo 000)"
    [ "${status}" = 201 ] || die "uploading ${digest} to ${HOST}/${ARTIFACT} answered HTTP ${status}"
}
identity() { # <manifest file>: what must match for a tag to count as this publication
    jq -S '{artifactType, config: {mediaType: .config.mediaType, digest: .config.digest},
        layers: [.layers[] | {mediaType, digest, size, title: .annotations["org.opencontainers.image.title"]}], annotations}' "$1"
}
SETTINGS="https://github.com/orgs/${OWNER}/packages/container/package/${REPOSITORY}"

# ---- upload both pools
declare -A DIGEST=()
for arch in "${ARCHES[@]}"; do
    tag="pool.${arch}.build-${C12}"
    status="$(auth pull,push cred)" || die "the token endpoint answered ${status} for push to ${HOST}/${ARTIFACT}"
    status="$(req GET "manifests/${tag}" "${WORK}/existing" -H "Accept: ${MANIFEST_TYPE}")"
    case "${status}" in
    200)
        [ "$(identity "${WORK}/existing")" = "$(identity "${WORK}/${arch}.manifest")" ] || {
            diff <(identity "${WORK}/existing") <(identity "${WORK}/${arch}.manifest") >&2 || true
            die "${HOST}/${ARTIFACT}:${tag} exists with other bytes or identity; a tag is never re-pointed"
        }
        cp "${WORK}/existing" "${WORK}/${arch}.manifest"
        echo "publish.sh: ${HOST}/${ARTIFACT}:${tag} exists with these bytes and identity"
        ;;
    404)
        blob_put "${WORK}/config"
        blob_put "${WORK}/${arch}.deb"
        status="$(req PUT "manifests/${tag}" /dev/null -H "Content-Type: ${MANIFEST_TYPE}" --data-binary @"${WORK}/${arch}.manifest")"
        [ "${status}" = 201 ] || die "putting ${HOST}/${ARTIFACT}:${tag} answered HTTP ${status}"
        echo "publish.sh: pushed ${HOST}/${ARTIFACT}:${tag}"
        ;;
    *) die "reading ${HOST}/${ARTIFACT}:${tag} with the push credential answered HTTP ${status}" ;;
    esac
    DIGEST[${arch}]="sha256:$(sha256sum "${WORK}/${arch}.manifest" | cut -d' ' -f1)"
done

# ---- anonymous read-back of every manifest and deb
for arch in "${ARCHES[@]}"; do
    tag="pool.${arch}.build-${C12}"
    status="$(auth pull anon)" || die "${HOST}/${ARTIFACT}:${tag} cannot be read anonymously (token endpoint HTTP ${status}): the package is private. Make it public at ${SETTINGS}, then rerun"
    for ref in "${tag}" "${DIGEST[${arch}]}"; do
        status="$(req GET "manifests/${ref}" "${WORK}/back" -H "Accept: ${MANIFEST_TYPE}")"
        [ "${status}" = 200 ] || die "${HOST}/${ARTIFACT}:${ref} cannot be read anonymously (HTTP ${status}): the package is private. Make it public at ${SETTINGS}, then rerun"
        [ "sha256:$(sha256sum "${WORK}/back" | cut -d' ' -f1)" = "${DIGEST[${arch}]}" ] || die "${HOST}/${ARTIFACT}:${ref} serves a manifest other than ${DIGEST[${arch}]}"
    done
    layer="$(jq -r '.layers[0].digest' "${WORK}/back")"
    status="$(req GET "blobs/${layer}" "${WORK}/back.deb" -L)"
    [ "${status}" = 200 ] || die "the deb ${layer} of ${HOST}/${ARTIFACT}:${tag} cannot be read anonymously (HTTP ${status})"
    [ "sha256:$(sha256sum "${WORK}/back.deb" | cut -d' ' -f1)" = "${layer}" ] || die "${HOST}/${ARTIFACT} serves ${layer} with other bytes"
    cmp -s "${WORK}/back.deb" "${WORK}/${arch}.deb" || die "${HOST}/${ARTIFACT} serves ${layer} with bytes other than _out/debs/${arch}"
    echo "publish.sh: ${HOST}/${ARTIFACT}:${tag} @${DIGEST[${arch}]} read back anonymously: $(jq -r '.layers[0].annotations["org.opencontainers.image.title"]' "${WORK}/back") ${layer}"
done

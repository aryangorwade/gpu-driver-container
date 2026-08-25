#!/usr/bin/env bash
# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Canonical Debian-family variant derived from scripts/generate-in-image-tpn.sh.
# Keep the copies in ubuntu22.04/, ubuntu24.04/, and ubuntu26.04/ synchronized
# with this file.
#
# The host generator's Syft inventory, package-owned license collection,
# standalone manifest, archive recovery, inventory collapse, and Markdown
# rendering are retained. Image building, Docker/registry access, platform
# merging, vGPU Manager handling, and parallel workers are removed because this
# script runs once inside the already-built target root filesystem.

set -euo pipefail

SYFT="${SYFT:-syft}"
JQ="${JQ:-jq}"
OUTPUT_DIR="${1:-${TPN_OUTPUT_DIR:-/licenses}}"
DOCUMENT_NAME="${TPN_DOCUMENT_NAME:-THIRD_PARTY_NOTICES.md}"
INVENTORY_NAME="${TPN_INVENTORY_NAME:-third-party-packages.tsv}"
TPN_SYFT_ALL_CATALOGERS="${TPN_SYFT_ALL_CATALOGERS:-0}"
TPN_RECOVER_ARCHIVES="${TPN_RECOVER_ARCHIVES:-1}"
TPN_FETCH_UPSTREAM="${TPN_FETCH_UPSTREAM:-1}"
TPN_STRICT="${TPN_STRICT:-0}"

# Syft cannot reliably map arbitrary binaries and scripts downloaded outside
# DPKG to an upstream name, version, and license.
# These are the things directly curled by the Dockerfile. 
standalone_manifest() {
    cat <<'EOF'
ubuntu22.04|/usr/local/bin/donkey|donkey|1.1.0|ISC|https://raw.githubusercontent.com/3XX0/donkey/v1.1.0/donkey.c|c-header|binary-stderr|https://github.com/3XX0/donkey
EOF
}

# The first four fields are copied from the host generator. The fifth field is
# the upstream license URL used because the vendored source tree is not present
# in the final image.
vgpu_module_manifest() {
    cat <<'EOF'
github.com/cpuguy83/go-md2man/v2|v2.0.7|MIT|github.com/cpuguy83/go-md2man/v2|https://raw.githubusercontent.com/cpuguy83/go-md2man/v2.0.7/LICENSE.md
github.com/russross/blackfriday/v2|v2.1.0|BSD-2-Clause|github.com/russross/blackfriday/v2|https://raw.githubusercontent.com/russross/blackfriday/v2.1.0/LICENSE.txt
github.com/sirupsen/logrus|v1.9.4|MIT|github.com/sirupsen/logrus|https://raw.githubusercontent.com/sirupsen/logrus/v1.9.4/LICENSE
github.com/urfave/cli/v2|v2.27.7|MIT / BSD-3-Clause|github.com/urfave/cli/v2|https://raw.githubusercontent.com/urfave/cli/v2.27.7/LICENSE
github.com/xrash/smetrics|v0.0.0-20240521201337-686a1a2994c1|MIT|github.com/xrash/smetrics|https://raw.githubusercontent.com/xrash/smetrics/686a1a2994c1/LICENSE
golang.org/x/sys|v0.13.0|BSD-3-Clause|golang.org/x/sys|https://raw.githubusercontent.com/golang/sys/v0.13.0/LICENSE
gopkg.in/yaml.v2|v2.4.0|Apache-2.0 / MIT|gopkg.in/yaml.v2|https://raw.githubusercontent.com/go-yaml/yaml/v2.4.0/LICENSE
EOF
}

WORK_ROOT=""
WARNINGS=0

die() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    if (( $# > 0 )); then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    printf 'WARNING: %s\n' "$*" >&2
}

cleanup() {
    if [[ -n "${WORK_ROOT}" && -d "${WORK_ROOT}" ]]; then
        chmod -R u+w "${WORK_ROOT}" 2>/dev/null || true
        rm -rf "${WORK_ROOT}"
    fi
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

check_boolean() {
    local name="$1" value="$2"
    [[ "${value}" == 0 || "${value}" == 1 ]] \
        || die "${name} must be 0 or 1."
}

hash_file() {
    sha256sum "$1" | awk '{print $1}'
}

safe_component() {
    printf '%s' "$1" | tr '/[:space:]' '__'
}

detect_distribution() {
    local id version
    [[ -r /etc/os-release ]] \
        || die "/etc/os-release is missing; cannot identify the distribution."

    id="$(. /etc/os-release >/dev/null 2>&1; printf '%s' "${ID:-}")"
    version="$(. /etc/os-release >/dev/null 2>&1; printf '%s' "${VERSION_ID:-}")"
    [[ -n "${id}" && -n "${version}" ]] \
        || die "/etc/os-release does not declare both ID and VERSION_ID."
    case "${id}" in
        ubuntu) DISTRIBUTION="ubuntu${version}" ;;
        *) die "unsupported distribution ${id}${version}; expected an Ubuntu image." ;;
    esac
}

detect_architecture() {
    local machine
    if [[ -n "${TARGETARCH:-}" ]]; then
        ARCHITECTURE="${TARGETARCH}"
        return
    fi

    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64) ARCHITECTURE="amd64" ;;
        aarch64|arm64) ARCHITECTURE="arm64" ;;
        ppc64le) ARCHITECTURE="ppc64le" ;;
        *) ARCHITECTURE="${machine}" ;;
    esac
}

validate_vgpu_binary_modules() {
    local json="$1" name version licenses relative url embedded_name embedded_version

    "${JQ}" -e --arg version "go${GOLANG_VERSION}" '
        any(.artifacts[];
            .type == "go-module"
            and .name == "stdlib"
            and .version == $version
            and any(.locations[]?;
                .path == "/usr/local/bin/vgpu-util"
                or .path == "usr/local/bin/vgpu-util"))
    ' "${json}" >/dev/null \
        || die "vgpu-util does not report expected Go standard library go${GOLANG_VERSION}."

    while IFS='|' read -r name version licenses relative url; do
        "${JQ}" -e --arg name "${name}" --arg version "${version}" '
            any(.artifacts[];
                .type == "go-module"
                and .name == $name
                and .version == $version
                and any(.locations[]?;
                    .path == "/usr/local/bin/vgpu-util"
                    or .path == "usr/local/bin/vgpu-util"))
        ' "${json}" >/dev/null \
            || die "vgpu-util does not report expected Go module ${name} ${version}."
    done < <(vgpu_module_manifest)

    while IFS=$'\t' read -r embedded_name embedded_version; do
        case "${embedded_name}" in
            ""|vgpu-util|command-line-arguments|stdlib) continue ;;
        esac
        vgpu_module_manifest \
            | awk -F '|' -v name="${embedded_name}" -v version="${embedded_version}" \
                '$1 == name && $2 == version { found = 1 } END { exit !found }' \
            || die "embedded Go module ${embedded_name} ${embedded_version} is missing from vgpu_module_manifest."
    done < <("${JQ}" -r '
        .artifacts[]
        | select(.type == "go-module")
        | select(any(.locations[]?;
            .path == "/usr/local/bin/vgpu-util"
            or .path == "usr/local/bin/vgpu-util"))
        | [.name, .version]
        | @tsv
    ' "${json}" | LC_ALL=C sort -u)
}

# This is scan_image() from the host generator with docker:<image> replaced by
# dir:/, because the final root filesystem is the current filesystem.
scan_rootfs() {
    local output="$1" package_keys="$2"
    local json="${WORK_ROOT}/rootfs.syft.json"
    local coverage="${PLATFORM} (${DRIVER_LABEL})"

    log "Scanning the final root filesystem with Syft..."
    if [[ "${TPN_SYFT_ALL_CATALOGERS}" == 1 || "${DRIVER_TYPE:-passthrough}" == vgpu ]]; then
        "${SYFT}" "dir:/" \
            --scope squashed \
            --source-name "nvidia-driver-container-${DISTRIBUTION}" \
            --source-version "${DRIVER_LABEL}" \
            -o "syft-json=${json}"
    else
        "${SYFT}" "dir:/" \
            --scope squashed \
            --source-name "nvidia-driver-container-${DISTRIBUTION}" \
            --source-version "${DRIVER_LABEL}" \
            --override-default-catalogers dpkg-db-cataloger \
            --select-catalogers=-file \
            -o "syft-json=${json}"
    fi

    if [[ "${DRIVER_TYPE:-passthrough}" == vgpu ]]; then
        [[ -n "${GOLANG_VERSION:-}" ]] \
            || die "GOLANG_VERSION is required to validate vgpu-util."
        validate_vgpu_binary_modules "${json}"
    fi

    # Normalize Syft's DEB records exactly as the host generator does.
    "${JQ}" -r --arg coverage "${coverage}" '
        .artifacts[]
        | select(.type == "deb")
        | [
            .name,
            .version,
            .type,
            (.metadata.architecture // .metadata.arch // "unknown"),
            (([.licenses[]?.value] | unique | join(" / ")) | if . == "" then "Unknown" else . end),
            (.purl // ""),
            $coverage
          ]
        | @tsv
    ' "${json}" >> "${output}"

    "${JQ}" -r '
        .artifacts[]
        | select(.type == "deb")
        | [.name, .version, (.metadata.architecture // .metadata.arch // "unknown")]
        | @tsv
    ' "${json}" | LC_ALL=C sort -u > "${package_keys}"
}

is_license_path() {
    local path flags base
    path="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    flags="$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    base="${path##*/}"

    [[ "${flags}" == *l* ]] && return 0
    case "${path}" in
        /usr/share/licenses/*|/usr/share/doc/*/copyright*) return 0 ;;
    esac
    case "${base}" in
        license|license[-._]*|licence|licence[-._]*|notice|notice[-._]*|\
        copying|copying[-._]*|copyright|copyright[-._]*|authors|authors[-._]*|\
        patents|patents[-._]*) return 0 ;;
    esac
    return 1
}

save_license_file() {
    local source="$1" destination="$2" suffix="$3"
    [[ -f "${source}" ]] || return 0
    mkdir -p "$(dirname "${destination}")"
    if [[ ! -e "${destination}" ]]; then
        cp -L "${source}" "${destination}" 2>/dev/null || return 0
    elif [[ "$(hash_file "${source}")" != "$(hash_file "${destination}")" ]]; then
        cp -L "${source}" "${destination}.${suffix}" 2>/dev/null || return 0
    fi
}

path_is_package_owned() {
    local ownership="$1" wanted="$2"
    awk -F '\t' -v wanted="${wanted}" '$4 == wanted { found = 1 } END { exit !found }' "${ownership}"
}

filter_inventory_ownership() {
    local package_keys="$1" ownership="$2"
    awk -F '\t' '
        NR == FNR { wanted[$1 SUBSEP $2 SUBSEP $3] = 1; next }
        (($1 SUBSEP $2 SUBSEP $3) in wanted) { print }
    ' "${package_keys}" "${ownership}"
}

# is_license_path() is copied for low-volume callers. Running it once for every
# package-owned path is prohibitively slow under buildx/QEMU because its `tr`
# calls create two processes per path. This is the same predicate in one awk
# pass, which is the necessary in-image adaptation.
filter_license_rows() {
    awk -F '\t' '
        {
            path = tolower($4)
            flags = tolower($5)
            if (index(flags, "l") > 0) { print; next }
            if (path ~ /^\/usr\/share\/licenses\//) { print; next }
            if (path ~ /^\/usr\/share\/doc\/.*\/copyright/) { print; next }
            n = split(path, segment, "/")
            base = segment[n]
            if (base ~ /^(license|licence|notice|copying|copyright|authors|patents)([-._]|$)/) {
                print
            }
        }
    '
}

# Copied from the host generator. It associates each license path with its
# package rather than assigning files through a blind filesystem scan.
package_file_query() {
    cat <<'EOF'
dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' |
while IFS=$(printf '\t') read -r installed status; do
    [ "$status" = installed ] || continue
    metadata=$(dpkg-query -W -f='${Package}\t${Version}\t${Architecture}' "$installed")
    dpkg-query -L "$installed" | while IFS= read -r path; do
        printf '%s\t%s\t\n' "$metadata" "$path"
    done
done
EOF
}

detect_standalone_version() {
    local path="$1" expected="$2" mode="$3"
    local detected digest output

    case "${mode}" in
        binary-stderr)
            output="$("${path}" 2>&1 || true)"
            detected="$(printf '%s\n' "${output}" | sed -n 's/^version: //p' | head -n 1)"
            [[ -n "${detected}" ]] \
                || die "could not detect the version of ${path}."
            [[ -z "${expected}" || "${detected}" == "${expected}" ]] \
                || die "${path} reports ${detected}, but its manifest expects ${expected}."
            printf '%s\n' "${detected}"
            ;;
        sha256)
            digest="$(hash_file "${path}")"
            printf 'sha256:%s\n' "${digest}"
            ;;
        version-sha256)
            digest="$(hash_file "${path}")"
            [[ -n "${expected}" ]] || die "${path} needs a declared project version."
            printf '%s+sha256.%s\n' "${expected}" "${digest}"
            ;;
        *)
            die "unknown standalone version mode '${mode}' for ${path}."
            ;;
    esac
}

download_standalone_license() {
    local url="$1" mode="$2" destination="$3"
    local download

    [[ -f "${destination}" ]] && return 0
    [[ "${TPN_FETCH_UPSTREAM}" == 1 ]] || return 1
    mkdir -p "$(dirname "${destination}")"
    download="$(mktemp "${WORK_ROOT}/standalone-license.XXXXXX")"
    curl -fsSL --retry 3 "${url}" > "${download}" || {
        rm -f "${download}"
        return 1
    }

    case "${mode}" in
        file)
            mv "${download}" "${destination}"
            ;;
        c-header)
            awk 'NR == 1 && $0 == "/*" { copying = 1 }
                 copying { print }
                 copying && $0 == " */" { exit }' "${download}" > "${destination}"
            rm -f "${download}"
            if [[ ! -s "${destination}" ]]; then
                rm -f "${destination}"
                return 1
            fi
            ;;
        *)
            rm -f "${download}"
            die "unknown standalone license mode '${mode}'."
            ;;
    esac
}

collect_standalone_components() {
    local distribution="$1" ownership="$2" license_root="$3" inventory="$4"
    local manifest_distribution path name expected license url license_mode version_mode source
    local version destination coverage

    coverage="${PLATFORM} (${DRIVER_LABEL})"
    while IFS='|' read -r manifest_distribution path name expected license url license_mode version_mode source; do
        [[ "${manifest_distribution}" == "${distribution}" ]] || continue
        [[ -f "${path}" ]] || continue
        path_is_package_owned "${ownership}" "${path}" && continue

        version="$(detect_standalone_version "${path}" "${expected}" "${version_mode}")"
        destination="${license_root}/${name}/${version}/${ARCHITECTURE}/upstream/LICENSE"
        download_standalone_license "${url}" "${license_mode}" "${destination}" \
            || warn "could not download the license text for ${name} from ${url}."

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${name}" "${version}" standalone "${ARCHITECTURE}" "${license}" "${source}" "${coverage}" \
            >> "${inventory}"
    done < <(standalone_manifest)
}

collect_image_licenses() {
    local distribution="$1" package_keys="$2" license_root="$3" inventory="$4"
    local ownership="${WORK_ROOT}/ownership.tsv"
    local query name version package_arch path flags relative destination suffix

    query="$(package_file_query "${distribution}")"
    bash -c "${query}" > "${ownership}"

    suffix="$(safe_component "${PLATFORM}")"
    while IFS=$'\t' read -r name version package_arch path flags; do
        [[ -n "${name}" && -n "${version}" && "${path}" == /* ]] || continue
        relative="${path#/}"
        destination="${license_root}/${name}/${version}/${package_arch}/${relative}"
        save_license_file "${path}" "${destination}" "${suffix}"
    done < <(filter_inventory_ownership "${package_keys}" "${ownership}" | filter_license_rows)

    collect_standalone_components \
        "${distribution}" "${ownership}" "${license_root}" "${inventory}"
}

collect_vgpu_go_dependencies() {
    local license_root="$1" inventory="$2"
    local coverage="${PLATFORM} (${DRIVER_LABEL})"
    local name version licenses relative url destination source_file

    while IFS='|' read -r name version licenses relative url; do
        destination="${license_root}/${name}/${version}/${ARCHITECTURE}/upstream"
        mkdir -p "${destination}"
        download_standalone_license "${url}" file "${destination}/LICENSE" \
            || warn "could not download the license text for Go module ${name} ${version}."

        # Preserve the two embedded notices extracted from vendored sources by
        # the host generator.
        if [[ "${name}" == github.com/sirupsen/logrus && "${TPN_FETCH_UPSTREAM}" == 1 ]]; then
            source_file="${WORK_ROOT}/logrus-alt-exit.go"
            if curl -fsSL --retry 3 \
                "https://raw.githubusercontent.com/sirupsen/logrus/${version}/alt_exit.go" \
                > "${source_file}"; then
                awk '
                    /^\/\/ The following code was sourced/ { copying = 1 }
                    copying {
                        line = $0
                        sub(/^\/\/ ?/, "", line)
                        print line
                    }
                    copying && /^\/\/ CONNECTION WITH THE SOFTWARE\.$/ { exit }
                ' "${source_file}" > "${destination}/ATEEXIT-LICENSE"
                [[ -s "${destination}/ATEEXIT-LICENSE" ]] \
                    || rm -f "${destination}/ATEEXIT-LICENSE"
            fi
        fi

        if [[ "${name}" == github.com/urfave/cli/v2 && "${TPN_FETCH_UPSTREAM}" == 1 ]]; then
            source_file="${WORK_ROOT}/urfave-sliceflag.go"
            if curl -fsSL --retry 3 \
                "https://raw.githubusercontent.com/urfave/cli/${version}/sliceflag.go" \
                > "${source_file}"; then
                awk '
                    /Copyright \(c\) 2009 The Go Authors/ { copying = 1 }
                    copying {
                        line = $0
                        sub(/^[[:space:]]*/, "", line)
                        sub(/[[:space:]]*$/, "", line)
                        print line
                    }
                    copying && /OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE\./ { exit }
                ' "${source_file}" > "${destination}/GO-FLAG-BSD-LICENSE"
                [[ -s "${destination}/GO-FLAG-BSD-LICENSE" ]] \
                    || rm -f "${destination}/GO-FLAG-BSD-LICENSE"
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${name}" "${version}" go-module "${ARCHITECTURE}" "${licenses}" \
            "pkg:golang/${name}@${version}" "${coverage}" >> "${inventory}"
    done < <(vgpu_module_manifest)

    version="go${GOLANG_VERSION}"
    destination="${license_root}/stdlib/${version}/${ARCHITECTURE}/upstream/LICENSE"
    download_standalone_license \
        "https://raw.githubusercontent.com/golang/go/${version}/LICENSE" file "${destination}" \
        || warn "could not download the Go standard library license for ${version}."
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        stdlib "${version}" go-standard-library "${ARCHITECTURE}" BSD-3-Clause \
        "pkg:golang/stdlib@${version}" "${coverage}" >> "${inventory}"
}

write_missing_packages() {
    local package_keys="$1" license_root="$2" output="$3"
    local name version package_arch
    : > "${output}"
    while IFS=$'\t' read -r name version package_arch; do
        if ! find "${license_root}/${name}/${version}/${package_arch}" -type f -print -quit 2>/dev/null | grep -q .; then
            printf '%s\t%s\t%s\n' "${name}" "${version}" "${package_arch}" >> "${output}"
        fi
    done < "${package_keys}"
}

# The host generator performs this work in a disposable container. This script
# itself already runs in a disposable TPN stage, so the commands can run here.
# Syft scans before this function installs any helper package.
download_missing_archives() {
    local _distribution="$1" missing="$2" output="$3"
    local name version package_arch archive archive_name archive_version archive_arch

    [[ -s "${missing}" ]] || return 0
    mkdir -p "${output}"

    while IFS=$'\t' read -r name version package_arch; do
        mkdir -p "${output}/${name}/${package_arch}"
        if [[ -d /usr/local/repos ]]; then
            while IFS= read -r archive; do
                archive_name="$(dpkg-deb -f "${archive}" Package)"
                archive_version="$(dpkg-deb -f "${archive}" Version)"
                archive_arch="$(dpkg-deb -f "${archive}" Architecture)"
                if [[ "${archive_name}" == "${name}" \
                    && "${archive_version}" == "${version}" \
                    && "${archive_arch}" == "${package_arch}" ]]; then
                    cp "${archive}" "${output}/${name}/${package_arch}/"
                fi
            done < <(find /usr/local/repos -maxdepth 1 -type f -name '*.deb' 2>/dev/null)
        fi
    done < "${missing}"

    apt-get update >/dev/null
    while IFS=$'\t' read -r name version package_arch; do
        find "${output}/${name}/${package_arch}" -type f -name '*.deb' -print -quit \
            | grep -q . && continue
        (cd "${output}/${name}/${package_arch}" \
            && apt-get download "${name}:${package_arch}=${version}") || true
    done < "${missing}"
}

collect_archive_licenses() {
    local distribution="$1" missing="$2" archives="$3" license_root="$4"
    local name version package_arch archive extract path relative suffix
    suffix="archive.$(safe_component "${PLATFORM}")"

    while IFS=$'\t' read -r name version package_arch; do
        [[ -d "${archives}/${name}/${package_arch}" ]] || continue
        while IFS= read -r -d '' archive; do
            extract="${WORK_ROOT}/archive-extract/$(safe_component \
                "${distribution}-${name}-${version}-${package_arch}-${RANDOM}")"
            mkdir -p "${extract}"
            dpkg-deb -x "${archive}" "${extract}"

            while IFS= read -r -d '' path; do
                relative="${path#${extract}/}"
                is_license_path "/${relative}" "" || continue
                save_license_file "${path}" \
                    "${license_root}/${name}/${version}/${package_arch}/${relative}" "${suffix}"
            done < <(find "${extract}" -type f -print0)
            chmod -R u+w "${extract}"
            rm -rf "${extract}"
        done < <(find "${archives}/${name}/${package_arch}" \
            -type f -name '*.deb' -print0)
    done < "${missing}"
}

# Some packages intentionally share notice text through a same-source sibling.
# That sharing is intentional; the link can become dangling when the sibling is
# absent or renamed. Archive extraction cannot repair a cross-package link, so
# this addition copies the sibling's recovered text and identifier.
# If a package's license text is unknown, this is a best-effort fallback.
recover_license_text_from_siblings() {
    local inventory="$1" license_root="$2"
    local source_map="${WORK_ROOT}/source-map.tsv"
    local haves="${WORK_ROOT}/source-haves.tsv"
    local inherited="${WORK_ROOT}/source-inherited.tsv"
    local name version _type package_arch license _rest
    local source sibling_root sibling_license package_root recovered=0

    dpkg-query -W -f='${Package}\t${source:Package}\t${db:Status-Status}\n' \
        | awk -F '\t' 'BEGIN { OFS = "\t" } $1 != "" && $3 == "installed" {
            print $1, ($2 == "" ? $1 : $2)
        }' > "${source_map}"
    [[ -s "${source_map}" ]] || return 0

    : > "${haves}"
    while IFS=$'\t' read -r name version _type package_arch license _rest; do
        package_root="${license_root}/${name}/${version}/${package_arch}"
        find "${package_root}" -type f -print -quit 2>/dev/null | grep -q . || continue
        source="$(awk -F '\t' -v name="${name}" '$1 == name { print $2; exit }' "${source_map}")"
        [[ -n "${source}" ]] || continue
        printf '%s\t%s\t%s\n' "${source}" "${package_root}" "${license}" >> "${haves}"
    done < "${inventory}"
    [[ -s "${haves}" ]] || return 0

    : > "${inherited}"
    while IFS=$'\t' read -r name version _type package_arch license _rest; do
        package_root="${license_root}/${name}/${version}/${package_arch}"
        find "${package_root}" -type f -print -quit 2>/dev/null | grep -q . && continue
        source="$(awk -F '\t' -v name="${name}" '$1 == name { print $2; exit }' "${source_map}")"
        [[ -n "${source}" ]] || continue
        sibling_root="$(awk -F '\t' -v source="${source}" '$1 == source { print $2; exit }' "${haves}")"
        [[ -n "${sibling_root}" && -d "${sibling_root}" ]] || continue
        mkdir -p "${package_root}"
        cp -R "${sibling_root}/." "${package_root}/" 2>/dev/null || continue
        recovered=$((recovered + 1))

        if [[ "${license}" == Unknown || "${license}" == NOASSERTION ]]; then
            sibling_license="$(awk -F '\t' -v source="${source}" '
                $1 == source && $3 != "" && $3 != "Unknown" && $3 != "NOASSERTION" {
                    print $3
                    exit
                }
            ' "${haves}")"
            [[ -n "${sibling_license}" ]] \
                && printf '%s\t%s\n' "${name}" "${sibling_license}" >> "${inherited}"
        fi
    done < "${inventory}"

    if [[ -s "${inherited}" ]]; then
        awk -F '\t' -v inherited="${inherited}" '
            BEGIN {
                OFS = "\t"
                while ((getline line < inherited) > 0) {
                    split(line, field, "\t")
                    license[field[1]] = field[2]
                }
                close(inherited)
            }
            { if ($1 in license) $5 = license[$1]; print }
        ' "${inventory}" > "${inventory}.new"
        mv "${inventory}.new" "${inventory}"
        log "Adopted a same-source license identifier for $(wc -l < "${inherited}" | tr -d ' ') component(s)."
    fi

    (( recovered > 0 )) \
        && log "Recovered license text for ${recovered} component(s) from same-source siblings."
    return 0
}

collapse_inventory() {
    LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k7,7 -u "$1" | awk -F '\t' '
        {
            key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
            if (!(key in present)) {
                present[key] = 1
                order[++count] = key
                name[key] = $1
                version[key] = $2
                type[key] = $3
                architecture[key] = $4
                purl[key] = $6
            }
            if (!((key SUBSEP $5) in license_seen)) {
                license_seen[key SUBSEP $5] = 1
                licenses[key] = licenses[key] (licenses[key] == "" ? "" : " / ") $5
            }
            if (!((key SUBSEP $7) in coverage_seen)) {
                coverage_seen[key SUBSEP $7] = 1
                coverage[key] = coverage[key] (coverage[key] == "" ? "" : ", ") $7
            }
        }
        END {
            OFS = "\t"
            for (i = 1; i <= count; i++) {
                key = order[i]
                print name[key], version[key], type[key], architecture[key], licenses[key], purl[key], coverage[key]
            }
        }
    '
}

fence_for() {
    local file="$1" longest width
    longest=$( (LC_ALL=C grep -oaE '`+' "${file}" 2>/dev/null || true) \
        | awk '{ if (length($0) > max) max = length($0) } END { print max+0 }')
    width=$((longest + 1))
    (( width < 3 )) && width=3
    printf '%*s' "${width}" '' | tr ' ' '`'
}

materialize_text() {
    local source="$1" destination="$2"
    case "${source}" in
        *.gz)
            command -v gzip >/dev/null 2>&1 || return 1
            gzip -cd "${source}" > "${destination}" 2>/dev/null
            ;;
        *.xz)
            command -v xz >/dev/null 2>&1 || return 1
            xz -cd "${source}" > "${destination}" 2>/dev/null
            ;;
        *.bz2)
            command -v bzip2 >/dev/null 2>&1 || return 1
            bzip2 -cd "${source}" > "${destination}" 2>/dev/null
            ;;
        *.zst|*.zstd)
            command -v zstd >/dev/null 2>&1 || return 1
            zstd -qcd "${source}" > "${destination}" 2>/dev/null
            ;;
        *)
            cp "${source}" "${destination}"
            ;;
    esac
}

emit_index() {
    local index="$1" name version type architecture licenses _purl _coverage
    printf '| Package | Version | Type | Architecture | License |\n'
    printf '|---------|---------|------|--------------|---------|\n'
    while IFS=$'\t' read -r name version type architecture licenses _purl _coverage; do
        printf '| `%s` | `%s` | %s | `%s` | %s |\n' \
            "${name}" "${version}" "${type}" "${architecture}" "${licenses}"
    done < "${index}"
}

emit_sections() {
    local index="$1" license_root="$2"
    local name version type architecture licenses _purl _coverage
    local package_root file relative text fence digest
    local hashes="${WORK_ROOT}/emitted-hashes"

    while IFS=$'\t' read -r name version type architecture licenses _purl _coverage; do
        printf '### %s %s (%s)\n\n' "${name}" "${version}" "${architecture}"
        printf '* License: %s\n' "${licenses}"
        printf '* Package type: %s\n' "${type}"
        printf '* Architecture: %s\n\n' "${architecture}"

        package_root="${license_root}/${name}/${version}/${architecture}"
        : > "${hashes}"
        if ! find "${package_root}" -type f -print -quit 2>/dev/null | grep -q .; then
            printf 'License text unavailable. See the package source for the full license.\n\n'
            continue
        fi

        while IFS= read -r -d '' file; do
            digest="$(hash_file "${file}")"
            grep -Fqx "${digest}" "${hashes}" && continue
            printf '%s\n' "${digest}" >> "${hashes}"

            relative="${file#${package_root}/}"
            text="${WORK_ROOT}/license-text"
            if ! materialize_text "${file}" "${text}"; then
                printf '#### %s\n\n' "${relative}"
                printf 'License text is stored in a compression format this image cannot decode.\n\n'
                continue
            fi
            fence="$(fence_for "${text}")"
            printf '#### %s\n\n' "${relative}"
            printf '%stext\n' "${fence}"
            cat "${text}"
            [[ ! -s "${text}" || $(tail -c 1 "${text}" | wc -l) -eq 1 ]] || printf '\n'
            printf '%s\n\n' "${fence}"
            rm -f "${text}"
        done < <(find "${package_root}" -type f -print0 | LC_ALL=C sort -z)
    done < "${index}"
}

compose_document() {
    local index="$1" license_root="$2"
    local output="${OUTPUT_DIR}/${DOCUMENT_NAME}"
    local temporary="${output}.tmp"

    log "Composing ${output}..."
    {
        printf '# Third-Party Notices\n\n'
        printf 'NVIDIA GPU driver container %s for %s\n\n' "${DRIVER_LABEL}" "${DISTRIBUTION}"
        printf 'This document covers packages discovered by Syft plus manifested standalone\n'
        printf 'components present in this final %s root filesystem. Build-stage-only\n' "${PLATFORM}"
        printf 'components are excluded.\n\n'

        printf '## Image Provenance\n\n'
        printf '| Field | Value |\n'
        printf '|-------|-------|\n'
        printf '| Distribution | `%s` |\n' "${DISTRIBUTION}"
        printf '| Architecture | `%s` |\n' "${PLATFORM}"
        printf '| Inventory scanner | `Syft %s` |\n' "$("${SYFT}" version -o json | "${JQ}" -r '.version')"
        [[ -n "${DRIVER_VERSION:-}" ]] && printf '| Driver version | `%s` |\n' "${DRIVER_VERSION}"
        [[ -n "${DRIVER_BRANCH:-}" ]] && printf '| Driver branch | `%s` |\n' "${DRIVER_BRANCH}"
        [[ -n "${DRIVER_TYPE:-}" ]] && printf '| Driver type | `%s` |\n' "${DRIVER_TYPE}"
        [[ -n "${KERNEL_VERSION:-}" ]] && printf '| Kernel version | `%s` |\n' "${KERNEL_VERSION}"
        [[ -n "${CVE_UPDATES:-}" ]] && printf '| CVE updates | `%s` |\n' "${CVE_UPDATES}"
        [[ -n "${GIT_COMMIT:-}" ]] && printf '| Source commit | `%s` |\n' "${GIT_COMMIT}"
        printf '\n'

        if [[ "${DRIVER_TYPE:-}" == vgpu ]]; then
            printf '**Scope limitation:** A release-specific vGPU/GRID driver `.run` payload is\n'
            printf 'supplied separately and is not covered by this document.\n\n'
        fi

        printf '## Dependency Index\n\n'
        emit_index "${index}"
        printf '\n## License Texts\n\n'
        emit_sections "${index}" "${license_root}"
    } > "${temporary}"

    chmod 644 "${temporary}"
    mv "${temporary}" "${output}"
    cp "${index}" "${OUTPUT_DIR}/${INVENTORY_NAME}"
    chmod 644 "${OUTPUT_DIR}/${INVENTORY_NAME}"
}

report_missing_license_text() {
    local index="$1" license_root="$2"
    local name version _type architecture _licenses _purl _coverage missing=0

    while IFS=$'\t' read -r name version _type architecture _licenses _purl _coverage; do
        if ! find "${license_root}/${name}/${version}/${architecture}" \
            -type f -print -quit 2>/dev/null | grep -q .; then
            missing=$((missing + 1))
            printf 'no license text for %s %s (%s)\n' \
                "${name}" "${version}" "${architecture}" >&2
        fi
    done < "${index}"

    if (( missing > 0 )); then
        warn "${missing} of $(wc -l < "${index}" | tr -d ' ') components have no license text."
    fi
}

report_unknown_licenses() {
    local index="$1" unknown
    unknown="$(cut -f5 "${index}" | LC_ALL=C grep -cE '(^| / )(Unknown|NOASSERTION)( / |$)' || true)"
    if (( unknown > 0 )); then
        warn "Syft reported an unknown license for ${unknown} component(s)."
    fi
}

main() {
    local raw_inventory package_keys license_root missing archives index
    local command

    for command in "${SYFT}" "${JQ}" curl awk sort grep find mktemp sha256sum; do
        require_command "${command}"
    done
    check_boolean TPN_SYFT_ALL_CATALOGERS "${TPN_SYFT_ALL_CATALOGERS}"
    check_boolean TPN_RECOVER_ARCHIVES "${TPN_RECOVER_ARCHIVES}"
    check_boolean TPN_FETCH_UPSTREAM "${TPN_FETCH_UPSTREAM}"
    check_boolean TPN_STRICT "${TPN_STRICT}"

    detect_distribution
    detect_architecture
    PLATFORM="linux/${ARCHITECTURE}"
    DRIVER_LABEL="${DRIVER_VERSION:-unknown}"

    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/in-image-tpn.XXXXXX")"
    raw_inventory="${WORK_ROOT}/inventory.tsv"
    package_keys="${WORK_ROOT}/packages.tsv"
    license_root="${WORK_ROOT}/licenses"
    missing="${WORK_ROOT}/missing.tsv"
    archives="${WORK_ROOT}/archives"
    index="${WORK_ROOT}/index.tsv"
    mkdir -p "${license_root}" "${OUTPUT_DIR}"
    : > "${raw_inventory}"

    scan_rootfs "${raw_inventory}" "${package_keys}"
    [[ -s "${package_keys}" ]] \
        || die "Syft found no DEB packages in the final root filesystem."

    collect_image_licenses \
        "${DISTRIBUTION}" "${package_keys}" "${license_root}" "${raw_inventory}"
    if [[ "${DRIVER_TYPE:-passthrough}" == vgpu ]]; then
        collect_vgpu_go_dependencies "${license_root}" "${raw_inventory}"
    fi

    # Resolve cross-package symlinks before archive recovery so only packages
    # that genuinely still lack text are downloaded.
    recover_license_text_from_siblings "${raw_inventory}" "${license_root}"
    write_missing_packages "${package_keys}" "${license_root}" "${missing}"
    if [[ "${TPN_RECOVER_ARCHIVES}" == 1 && -s "${missing}" ]]; then
        log "Recovering license text from exact installed package archives..."
        download_missing_archives "${DISTRIBUTION}" "${missing}" "${archives}"
        collect_archive_licenses \
            "${DISTRIBUTION}" "${missing}" "${archives}" "${license_root}"
    fi

    # An archive may provide the first usable text for a source-package family.
    recover_license_text_from_siblings "${raw_inventory}" "${license_root}"
    collapse_inventory "${raw_inventory}" > "${index}"
    [[ -s "${index}" ]] || die "Syft produced an empty component index."

    report_unknown_licenses "${index}"
    report_missing_license_text "${index}" "${license_root}"
    compose_document "${index}" "${license_root}"

    log "Wrote ${OUTPUT_DIR}/${DOCUMENT_NAME} covering $(wc -l < "${index}" | tr -d ' ') components."
    if (( WARNINGS > 0 )); then
        if [[ "${TPN_STRICT}" == 1 ]]; then
            die "${WARNINGS} warning(s) were raised and TPN_STRICT=1."
        fi
        log "${WARNINGS} warning(s) were raised; set TPN_STRICT=1 to treat these as fatal."
    fi
}

main "$@"

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
#
# Generates third-party-notices documents under <repo-root>/tpn/:
#   tpn/<driver-version>-<distribution>.md   passthrough (DRIVER_TYPE=passthrough)
#   tpn/vgpu/<distribution>.md               vgpu-util support layer (DRIVER_TYPE=vgpu)
#   tpn/vgpu-manager/<driver-version>-<distribution>.md   vGPU Manager host image
# Each document merges linux/amd64 and linux/arm64.
#
# RIGHT NOW: Ignore both vgpu-util and vgpu-manager. Delete unsupported distro * driver configs.
# Get the exact driver versions being used. Below comments are OUTDATED.
# The script also does not include deps for base images OR drivers. Those will have to be appended manually.
#
# When DRIVER_TYPE is set to vgpu instead of passthrough, the consumer has to
# manually add the driver installer binary to the driver folder. This is why that 
# driver installer binary's dependencies are ignored. But the vgpu-util binary is 
# built into the container image, so its deps must be added to the TPN for each 
# distribution using go-licenses. Additionally, the built container is inspected by Syft.
#
# The vGPU Manager host image (vgpu-manager/<distribution>/Dockerfile) is a
# separate image family entirely, not built into any of the above. It similarly
# requires a manually supplied driver installer binary in the driver folder, and so 
# this installer's deps are ignored. However, it does not contain a Go binary, so 
# only its built container is inspected by Syft.
#
# NOTE: 580.178.04-ubuntu26.04 passthrough image is EXCLUDED from CI matrix. Reevalute this one. <-------- TODO
#
# TODO: Dynamically generate TPN in a container build and bake it in. Do: 
# - Discard the disposable image build logic
# - Discard the placeholder-runfile for vgpu-manager
# - Instead of building for both arm64 and amd64 linux, only one build is needed
# - Remove the build parallelism
# - Change output destination to baking it into Dockerfile
#
# Coverage disclaimer:
# RPM/DPKG dependencies are discovered automatically from the final images, but
# software copied or downloaded outside those package managers is covered only
# when listed in standalone_manifest. The current Dockerfiles and install
# scripts were manually audited for those artifacts. Re-audit and update the
# manifest whenever an image definition or installation path changes; this
# generator cannot guarantee discovery of a newly added unmanaged component.
#
# Examples:
#   ./scripts/generate-driver-image-third-party-notices.sh
#   TPN_JOBS=3 TPN_DISTRIBUTIONS="rhel8 ubuntu24.04" ./scripts/generate-driver-image-third-party-notices.sh
#   TPN_INCLUDE_VGPU=0 ./scripts/generate-driver-image-third-party-notices.sh
#   TPN_VGPU_MANAGER_VERSIONS="550.144.02" ./scripts/generate-driver-image-third-party-notices.sh
#   TPN_DRY_RUN=1 ./scripts/generate-driver-image-third-party-notices.sh

set -euo pipefail

readonly ALL_DISTRIBUTIONS=(
    rhel8
    rhel9
    rhel10
    ubuntu22.04
    ubuntu24.04
    ubuntu26.04
)
# vgpu-manager/ has its own Dockerfile tree, a strict subset of ALL_DISTRIBUTIONS.
readonly ALL_VGPU_MANAGER_DISTRIBUTIONS=(
    rhel8
    rhel9
    rhel10
    ubuntu22.04
    ubuntu24.04
)
# Syft cannot reliably map arbitrary binaries and scripts downloaded outside
# RPM/DPKG to an upstream name, version, and license. The explicit manifest is
# the fix: collection still requires the path in the final image and skips it
# when the package database owns it. Version probes use the final artifact
# where possible; unversioned upstream files use their SHA-256.
standalone_manifest() {
    cat <<'EOF'
rhel8|/usr/local/bin/donkey|donkey|1.1.0|ISC|https://raw.githubusercontent.com/3XX0/donkey/v1.1.0/donkey.c|c-header|binary-stderr|https://github.com/3XX0/donkey
rhel8|/usr/local/bin/extract-vmlinux|extract-vmlinux||GPL-2.0-only|https://raw.githubusercontent.com/torvalds/linux/master/LICENSES/preferred/GPL-2.0|file|sha256|https://github.com/torvalds/linux
rhel9|/usr/local/bin/donkey|donkey|1.1.0|ISC|https://raw.githubusercontent.com/3XX0/donkey/v1.1.0/donkey.c|c-header|binary-stderr|https://github.com/3XX0/donkey
rhel9|/usr/local/bin/extract-vmlinux|extract-vmlinux||GPL-2.0-only|https://raw.githubusercontent.com/torvalds/linux/master/LICENSES/preferred/GPL-2.0|file|sha256|https://github.com/torvalds/linux
rhel10|/usr/local/bin/donkey|donkey|1.1.0|ISC|https://raw.githubusercontent.com/3XX0/donkey/v1.1.0/donkey.c|c-header|binary-stderr|https://github.com/3XX0/donkey
rhel10|/usr/local/bin/extract-vmlinux|extract-vmlinux||GPL-2.0-only|https://raw.githubusercontent.com/torvalds/linux/master/LICENSES/preferred/GPL-2.0|file|sha256|https://github.com/torvalds/linux
rhel10|/usr/bin/unzboot|unzboot|0.1|GPL-2.0-or-later|https://raw.githubusercontent.com/eballetbo/unzboot/main/LICENSE|file|version-sha256|https://github.com/eballetbo/unzboot
ubuntu22.04|/usr/local/bin/donkey|donkey|1.1.0|ISC|https://raw.githubusercontent.com/3XX0/donkey/v1.1.0/donkey.c|c-header|binary-stderr|https://github.com/3XX0/donkey
EOF
}

vgpu_module_manifest() {
    cat <<'EOF'
github.com/cpuguy83/go-md2man/v2|v2.0.7|MIT|github.com/cpuguy83/go-md2man/v2
github.com/russross/blackfriday/v2|v2.1.0|BSD-2-Clause|github.com/russross/blackfriday/v2
github.com/sirupsen/logrus|v1.9.4|MIT|github.com/sirupsen/logrus
github.com/urfave/cli/v2|v2.27.7|MIT / BSD-3-Clause|github.com/urfave/cli/v2
github.com/xrash/smetrics|v0.0.0-20240521201337-686a1a2994c1|MIT|github.com/xrash/smetrics
golang.org/x/sys|v0.13.0|BSD-3-Clause|golang.org/x/sys
gopkg.in/yaml.v2|v2.4.0|Apache-2.0 / MIT|gopkg.in/yaml.v2
EOF
}

DOCKER="${DOCKER:-docker}"
SYFT="${SYFT:-syft}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSIONS_MK="${VERSIONS_MK:-${REPO_ROOT}/versions.mk}"
VGPU_VENDOR_ROOT="${VGPU_VENDOR_ROOT:-${REPO_ROOT}/vgpu/src/vendor}"
VGPU_MODULES_FILE="${VGPU_MODULES_FILE:-${VGPU_VENDOR_ROOT}/modules.txt}"
TPN_OUTPUT_DIR="${TPN_OUTPUT_DIR:-${REPO_ROOT}/tpn}"
TPN_JOBS="${TPN_JOBS:-3}"
TPN_DISTRIBUTIONS="${TPN_DISTRIBUTIONS:-}"
TPN_PLATFORMS="${TPN_PLATFORMS:-linux/amd64 linux/arm64}"
TPN_DRY_RUN="${TPN_DRY_RUN:-0}"
TPN_INCLUDE_VGPU="${TPN_INCLUDE_VGPU:-1}"
TPN_INCLUDE_VGPU_MANAGER="${TPN_INCLUDE_VGPU_MANAGER:-1}"
TPN_VGPU_MANAGER_VERSIONS="${TPN_VGPU_MANAGER_VERSIONS:-}"
TPN_SELECTIVE_EXPORT="${TPN_SELECTIVE_EXPORT:-1}"
TPN_SYFT_ALL_CATALOGERS="${TPN_SYFT_ALL_CATALOGERS:-0}"
TPN_WORKER_DISTRIBUTION="${TPN_WORKER_DISTRIBUTION:-}"
TPN_WORKER_DRIVER_VERSION="${TPN_WORKER_DRIVER_VERSION:-}"
TPN_WORKER_DRIVER_TYPE="${TPN_WORKER_DRIVER_TYPE:-}"

SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
cd "${REPO_ROOT}"

WORK_ROOT=""
CURRENT_CONTAINER=""
PREPARED_IMAGE=""
PREPARED_IMAGE_IS_TEMP=0
TEMP_IMAGES=()
OUT_TEMPS=()
WORKER_PIDS=()
DISTRIBUTION_LIST=()
PLATFORM_LIST=()
DRIVER_VERSION_LIST=()
VGPU_MANAGER_DISTRIBUTION_LIST=()
VGPU_MANAGER_VERSION_LIST=()

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

cleanup() {
    local image tmp pid
    # Bash 3 treats an empty array expansion as unset under nounset.
    set +u
    if [[ -n "${CURRENT_CONTAINER}" ]]; then
        "${DOCKER}" rm -f "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
    fi
    for image in "${TEMP_IMAGES[@]}"; do
        "${DOCKER}" image rm -f "${image}" >/dev/null 2>&1 || true
    done
    for tmp in "${OUT_TEMPS[@]}"; do
        rm -f "${tmp}"
    done
    for pid in "${WORKER_PIDS[@]}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
    if [[ -n "${WORK_ROOT}" ]]; then
        chmod -R u+w "${WORK_ROOT}" 2>/dev/null || true
        rm -rf "${WORK_ROOT}"
    fi
}

handle_signal() {
    local status="$1"
    trap - INT TERM
    cleanup
    exit "${status}"
}

trap cleanup EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

read_make_variable() {
    local name="$1"
    awk -v name="${name}" '
        $1 == name && ($2 == "?=" || $2 == ":=" || $2 == "=") {
            for (i = 3; i <= NF; i++) printf "%s%s", (i == 3 ? "" : " "), $i
            print ""
            exit
        }
    ' "${VERSIONS_MK}"
}

is_supported_distribution() {
    local wanted="$1" distribution
    for distribution in "${ALL_DISTRIBUTIONS[@]}"; do
        [[ "${distribution}" == "${wanted}" ]] && return 0
    done
    return 1
}

is_supported_vgpu_manager_distribution() {
    local wanted="$1" distribution
    for distribution in "${ALL_VGPU_MANAGER_DISTRIBUTIONS[@]}"; do
        [[ "${distribution}" == "${wanted}" ]] && return 0
    done
    return 1
}

# Mirrors .github/workflows/image.yaml's matrix "exclude" and
# .common-ci.yml's .driver-versions-ubuntu26.04: this combination is never
# built by the release pipeline, so it is not scanned for a TPN either.
is_excluded_passthrough_combo() {
    local distribution="$1" driver_version="$2"
    [[ "${distribution}" == ubuntu26.04 && "${driver_version}" == 580.178.04 ]]
}

configure_lists() {
    local distribution

    if [[ -n "${TPN_WORKER_DISTRIBUTION}" ]]; then
        DISTRIBUTION_LIST=("${TPN_WORKER_DISTRIBUTION}")
    elif [[ -n "${TPN_DISTRIBUTIONS}" ]]; then
        read -r -a DISTRIBUTION_LIST <<< "${TPN_DISTRIBUTIONS}"
    else
        DISTRIBUTION_LIST=("${ALL_DISTRIBUTIONS[@]}")
    fi
    (( ${#DISTRIBUTION_LIST[@]} > 0 )) || die "no distributions were selected."

    for distribution in "${DISTRIBUTION_LIST[@]}"; do
        is_supported_distribution "${distribution}" \
            || die "unsupported distribution '${distribution}'."
        [[ -d "${distribution}" ]] || die "${distribution} directory not found."
        [[ -f "${distribution}/Dockerfile" ]] \
            || die "${distribution}/Dockerfile not found."
    done

    if [[ -n "${TPN_WORKER_DRIVER_VERSION}" ]]; then
        DRIVER_VERSION_LIST=("${TPN_WORKER_DRIVER_VERSION}")
    else
        read -r -a DRIVER_VERSION_LIST <<< "${DRIVER_VERSIONS}"
    fi
    read -r -a PLATFORM_LIST <<< "${TPN_PLATFORMS}"
    (( ${#DRIVER_VERSION_LIST[@]} > 0 )) || die "no driver versions were selected."
    (( ${#PLATFORM_LIST[@]} > 0 )) || die "no platforms were selected."

    if [[ "${TPN_WORKER_DRIVER_TYPE}" == passthrough ]] \
        && is_excluded_passthrough_combo "${TPN_WORKER_DISTRIBUTION}" "${TPN_WORKER_DRIVER_VERSION}"; then
        die "${TPN_WORKER_DISTRIBUTION} ${TPN_WORKER_DRIVER_VERSION} is excluded from the release matrix." \
            "See .github/workflows/image.yaml's matrix exclude and .common-ci.yml's .driver-versions-ubuntu26.04."
    fi

    # vgpu-manager has its own Dockerfile tree and no version list in
    # versions.mk, so it is only planned by the orchestrator (never inside a
    # single-task worker, which already knows its exact distribution/version
    # via TPN_WORKER_DISTRIBUTION/TPN_WORKER_DRIVER_VERSION).
    if [[ -z "${TPN_WORKER_DRIVER_TYPE}" ]]; then
        if [[ "${TPN_INCLUDE_VGPU_MANAGER}" == 1 && -n "${TPN_VGPU_MANAGER_VERSIONS}" ]]; then
            if [[ -n "${TPN_DISTRIBUTIONS}" ]]; then
                read -r -a VGPU_MANAGER_DISTRIBUTION_LIST <<< "${TPN_DISTRIBUTIONS}"
            else
                VGPU_MANAGER_DISTRIBUTION_LIST=("${ALL_VGPU_MANAGER_DISTRIBUTIONS[@]}")
            fi
            read -r -a VGPU_MANAGER_VERSION_LIST <<< "${TPN_VGPU_MANAGER_VERSIONS}"
            for distribution in "${VGPU_MANAGER_DISTRIBUTION_LIST[@]}"; do
                is_supported_vgpu_manager_distribution "${distribution}" \
                    || die "unsupported vgpu-manager distribution '${distribution}'."
                [[ -f "vgpu-manager/${distribution}/Dockerfile" ]] \
                    || die "vgpu-manager/${distribution}/Dockerfile not found."
            done
        elif [[ "${TPN_INCLUDE_VGPU_MANAGER}" == 1 ]]; then
            log "Skipping vgpu-manager TPNs: set TPN_VGPU_MANAGER_VERSIONS to generate them."
        fi
    fi
}

check_boolean() {
    local name="$1" value="$2"
    [[ "${value}" == 0 || "${value}" == 1 ]] \
        || die "${name} must be 0 or 1."
}

validate_vgpu_module_manifest() {
    local name version licenses relative vendored_name vendored_version

    [[ -f "${VGPU_MODULES_FILE}" ]] || die "${VGPU_MODULES_FILE} not found."
    while IFS='|' read -r name version licenses relative; do
        [[ -n "${name}" && -n "${version}" && -n "${licenses}" && -n "${relative}" ]] \
            || die "invalid vgpu module manifest entry."
        grep -Fqx "# ${name} ${version}" "${VGPU_MODULES_FILE}" \
            || die "${name} ${version} is not recorded in ${VGPU_MODULES_FILE}."
        [[ -d "${VGPU_VENDOR_ROOT}/${relative}" ]] \
            || die "vendored module directory ${VGPU_VENDOR_ROOT}/${relative} not found."
    done < <(vgpu_module_manifest)

    while IFS='|' read -r vendored_name vendored_version; do
        vgpu_module_manifest \
            | awk -F '|' -v name="${vendored_name}" -v version="${vendored_version}" \
                '$1 == name && $2 == version { found = 1 } END { exit !found }' \
            || die "vendored module ${vendored_name} ${vendored_version} is missing from vgpu_module_manifest."
    done < <(awk '/^# / && $3 !~ /^=>/ { print $2 "|" $3 }' "${VGPU_MODULES_FILE}")
}

check_prerequisites() {
    local command
    [[ -f "${VERSIONS_MK}" ]] \
        || die "${VERSIONS_MK} not found."

    GOLANG_VERSION="${GOLANG_VERSION:-$(read_make_variable GOLANG_VERSION)}"
    DRIVER_VERSIONS="${DRIVER_VERSIONS:-$(read_make_variable DRIVER_VERSIONS)}"
    [[ -n "${GOLANG_VERSION}" ]] \
        || die "could not read GOLANG_VERSION from ${VERSIONS_MK}."
    [[ -n "${DRIVER_VERSIONS}" ]] \
        || die "could not read DRIVER_VERSIONS from ${VERSIONS_MK}."
    [[ "${TPN_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "TPN_JOBS must be a positive integer."
    check_boolean TPN_SELECTIVE_EXPORT "${TPN_SELECTIVE_EXPORT}"
    check_boolean TPN_SYFT_ALL_CATALOGERS "${TPN_SYFT_ALL_CATALOGERS}"
    check_boolean TPN_DRY_RUN "${TPN_DRY_RUN}"
    check_boolean TPN_INCLUDE_VGPU "${TPN_INCLUDE_VGPU}"
    check_boolean TPN_INCLUDE_VGPU_MANAGER "${TPN_INCLUDE_VGPU_MANAGER}"

    configure_lists
    if [[ "${TPN_INCLUDE_VGPU}" == 1 || "${TPN_WORKER_DRIVER_TYPE}" == vgpu ]]; then
        validate_vgpu_module_manifest
    fi
    [[ "${TPN_DRY_RUN}" == 1 ]] && return 0

    for command in "${DOCKER}" "${SYFT}" curl jq awk sort grep find tar mktemp gzip xz bzip2 zstd cpio rpm2cpio dpkg-deb; do
        require_command "${command}"
    done
    if command -v sha256sum >/dev/null 2>&1; then
        HASH_COMMAND=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        HASH_COMMAND=shasum
    else
        die "sha256sum or shasum is required."
    fi
    "${DOCKER}" info >/dev/null 2>&1 || die "the Docker daemon is unavailable."
    "${DOCKER}" buildx version >/dev/null 2>&1 || die "Docker Buildx is required."

    # Values discovered from versions.mk must be available to worker processes.
    export DOCKER SYFT VERSIONS_MK GOLANG_VERSION DRIVER_VERSIONS
    export VGPU_VENDOR_ROOT VGPU_MODULES_FILE
    export TPN_OUTPUT_DIR TPN_PLATFORMS TPN_INCLUDE_VGPU TPN_INCLUDE_VGPU_MANAGER
    export TPN_SELECTIVE_EXPORT TPN_SYFT_ALL_CATALOGERS
}

hash_file() {
    if [[ "${HASH_COMMAND}" == sha256sum ]]; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

safe_component() {
    printf '%s' "$1" | tr '/[:space:]' '__'
}

# BuildKit is the source of truth: every scanned image is built fresh from
# this repository's own Dockerfiles.
prepare_image() {
    local distribution="$1" platform="$2" driver_version="$3" driver_type="$4"
    local driver_branch="${driver_version%%.*}"

    PREPARED_IMAGE_IS_TEMP=1
    PREPARED_IMAGE="tpn-${driver_type}-${distribution}-${platform#*/}-${driver_version}-${$}:local"
    TEMP_IMAGES+=("${PREPARED_IMAGE}")
    log "Building ${driver_type} ${distribution} ${driver_version} for ${platform}..."

    if [[ "${driver_type}" == vgpu-manager ]]; then
        build_vgpu_manager_image "${distribution}" "${platform}" "${driver_version}"
        return
    fi

    DOCKER_BUILDKIT=1 "${DOCKER}" buildx build \
        --pull \
        --platform "${platform}" \
        --load \
        --tag "${PREPARED_IMAGE}" \
        --build-arg "DRIVER_TYPE=${driver_type}" \
        --build-arg "DRIVER_VERSION=${driver_version}" \
        --build-arg "DRIVER_BRANCH=${driver_branch}" \
        --build-arg "GOLANG_VERSION=${GOLANG_VERSION}" \
        --build-arg "CVE_UPDATES=${CVE_UPDATES:-}" \
        --build-arg "GIT_COMMIT=${GIT_COMMIT:-}" \
        --file "${distribution}/Dockerfile" \
        "${distribution}"
}

# vgpu-manager/<distribution>/Dockerfile unconditionally COPYs/ADDs a named
# NVIDIA-Linux-<arch>-<version>-vgpu-kvm.run installer and never inspects its
# contents (see standalone_manifest's rationale for why Syft cannot map such
# a file to license text either). A zero-byte placeholder with the expected
# name therefore satisfies the build identically to the real, licensed
# installer for TPN purposes. If a real installer is already present, it is
# used instead. Either way the real vgpu-manager/<distribution>/ directory is
# never modified; the build runs from a scratch copy.
build_vgpu_manager_image() {
    local distribution="$1" platform="$2" driver_version="$3"
    local arch="${platform#*/}"
    local context="${WORK_ROOT}/vgpu-manager-context/$(safe_component "${distribution}-${platform}")"
    local runfile_name

    arch="${arch/amd64/x86_64}"
    arch="${arch/arm64/aarch64}"
    runfile_name="NVIDIA-Linux-${arch}-${driver_version}-vgpu-kvm.run"

    rm -rf "${context}"
    mkdir -p "${context}"
    cp -R "vgpu-manager/${distribution}/." "${context}/"
    if ! find "${context}" -maxdepth 1 -name 'NVIDIA-Linux-*-vgpu-kvm.run' -print -quit | grep -q .; then
        : > "${context}/${runfile_name}"
    fi

    DOCKER_BUILDKIT=1 "${DOCKER}" buildx build \
        --pull \
        --platform "${platform}" \
        --load \
        --tag "${PREPARED_IMAGE}" \
        --build-arg "DRIVER_VERSION=${driver_version}" \
        --build-arg "DRIVER_ARCH=${arch}" \
        --build-arg "CVE_UPDATES=${CVE_UPDATES:-}" \
        --build-arg "GIT_COMMIT=${GIT_COMMIT:-}" \
        --file "${context}/Dockerfile" \
        "${context}"

    chmod -R u+w "${context}"
    rm -rf "${context}"
}

validate_vgpu_binary_modules() {
    local json="$1" name version licenses relative embedded_name embedded_version

    jq -e --arg version "go${GOLANG_VERSION}" '
        any(.artifacts[];
            .type == "go-module"
            and .name == "stdlib"
            and .version == $version
            and any(.locations[]?; .path == "/usr/local/bin/vgpu-util"))
    ' "${json}" >/dev/null \
        || die "vgpu-util does not report expected Go standard library go${GOLANG_VERSION}."

    while IFS='|' read -r name version licenses relative; do
        jq -e --arg name "${name}" --arg version "${version}" '
            any(.artifacts[];
                .type == "go-module"
                and .name == $name
                and .version == $version
                and any(.locations[]?; .path == "/usr/local/bin/vgpu-util"))
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
    done < <(jq -r '
        .artifacts[]
        | select(.type == "go-module")
        | select(any(.locations[]?; .path == "/usr/local/bin/vgpu-util"))
        | [.name, .version]
        | @tsv
    ' "${json}" | LC_ALL=C sort -u)
}

assert_vgpu_payload_absent() {
    local image="$1" platform="$2"

    if "${DOCKER}" run --rm --platform "${platform}" \
        --entrypoint /bin/bash "${image}" \
        -c 'find /drivers -type f -name "*.run" -print -quit | grep -q .'; then
        die "${image} contains a vGPU/GRID .run payload." \
            "The vgpu-util support-layer documents intentionally exclude that payload;" \
            "generate a release-specific notice for the complete vGPU image instead."
    fi
}

# Native Syft JSON keeps more package metadata than presentation formats.
# Only the installed RPM and DPKG databases are needed; standalone artifacts
# are verified separately through standalone_manifest.
scan_image() {
    local image="$1" platform="$2" driver_version="$3" output="$4" driver_type="$5"
    local json="${WORK_ROOT}/$(safe_component "${image}-${platform}").syft.json"

    log "Scanning ${image}..."
    if [[ "${TPN_SYFT_ALL_CATALOGERS}" == 1 || "${driver_type}" == vgpu ]]; then
        "${SYFT}" "docker:${image}" \
            --platform "${platform}" \
            --scope squashed \
            -o "syft-json=${json}"
    else
        "${SYFT}" "docker:${image}" \
            --platform "${platform}" \
            --scope squashed \
            --override-default-catalogers rpm-db-cataloger \
            --override-default-catalogers dpkg-db-cataloger \
            --select-catalogers=-file \
            -o "syft-json=${json}"
    fi
    if [[ "${driver_type}" == vgpu ]]; then
        validate_vgpu_binary_modules "${json}"
    fi

    # Normalize Syft's RPM/DEB records. RPM represents imported signing keys as
    # gpg-pubkey pseudo-packages; they have no software payload or package archive.
    jq -r --arg coverage "${platform} (${driver_version})" '
        .artifacts[]
        | select(.type == "rpm" or .type == "deb")
        | select(.name != "gpg-pubkey")
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

    jq -r '
        .artifacts[]
        | select(.type == "rpm" or .type == "deb")
        | select(.name != "gpg-pubkey")
        | [.name, .version, (.metadata.architecture // .metadata.arch // "unknown")]
        | @tsv
    ' "${json}" | LC_ALL=C sort -u
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
        cp -L "${source}" "${destination}"
    elif ! cmp -s "${source}" "${destination}"; then
        cp -L "${source}" "${destination}.${suffix}"
    fi
}

collect_vgpu_go_dependencies() {
    local platform="$1" driver_version="$2" license_root="$3" inventory="$4"
    local architecture="${platform#*/}" coverage="${platform} (${driver_version})"
    local name version licenses relative module_root destination file

    while IFS='|' read -r name version licenses relative; do
        module_root="${VGPU_VENDOR_ROOT}/${relative}"
        destination="${license_root}/${name}/${version}/${architecture}/vendor"
        mkdir -p "${destination}"

        while IFS= read -r -d '' file; do
            is_license_path "/$(basename "${file}")" "" || continue
            save_license_file "${file}" "${destination}/$(basename "${file}")" \
                "$(safe_component "${platform}")"
        done < <(find "${module_root}" -maxdepth 1 -type f -print0)

        # logrus contains modified code from github.com/tebeka/atexit whose MIT
        # notice is embedded in the source rather than a standalone license file.
        if [[ "${name}" == github.com/sirupsen/logrus ]]; then
            awk '
                /^\/\/ The following code was sourced/ { copying = 1 }
                copying {
                    line = $0
                    sub(/^\/\/ ?/, "", line)
                    print line
                }
                copying && /^\/\/ CONNECTION WITH THE SOFTWARE\.$/ { exit }
            ' "${module_root}/alt_exit.go" > "${destination}/ATEEXIT-LICENSE"
            [[ -s "${destination}/ATEEXIT-LICENSE" ]] \
                || die "could not extract the embedded atexit license from logrus."
        fi

        # urfave/cli carries modified Go flag-package code and its BSD notice
        # inline in sliceflag.go.
        if [[ "${name}" == github.com/urfave/cli/v2 ]]; then
            awk '
                /Copyright \(c\) 2009 The Go Authors/ { copying = 1 }
                copying {
                    line = $0
                    sub(/^[[:space:]]*/, "", line)
                    sub(/[[:space:]]*$/, "", line)
                    print line
                }
                copying && /OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE\./ { exit }
            ' "${module_root}/sliceflag.go" > "${destination}/GO-FLAG-BSD-LICENSE"
            [[ -s "${destination}/GO-FLAG-BSD-LICENSE" ]] \
                || die "could not extract the embedded Go flag license from urfave/cli."
        fi

        find "${destination}" -type f -print -quit | grep -q . \
            || die "no vendored license text found for ${name} ${version}."
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${name}" "${version}" go-module "${architecture}" "${licenses}" \
            "pkg:golang/${name}@${version}" "${coverage}" >> "${inventory}"
    done < <(vgpu_module_manifest)

    version="go${GOLANG_VERSION}"
    destination="${license_root}/stdlib/${version}/${architecture}/upstream/LICENSE"
    download_standalone_license \
        "https://raw.githubusercontent.com/golang/go/${version}/LICENSE" file "${destination}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        stdlib "${version}" go-standard-library "${architecture}" BSD-3-Clause \
        "pkg:golang/stdlib@${version}" "${coverage}" >> "${inventory}"
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

detect_standalone_version() {
    local image="$1" platform="$2" path="$3" expected="$4" mode="$5" rootfs="$6"
    local detected digest output

    case "${mode}" in
        binary-stderr)
            output=$("${DOCKER}" run --rm --platform "${platform}" \
                --entrypoint "${path}" "${image}" 2>&1 || true)
            detected=$(printf '%s\n' "${output}" | sed -n 's/^version: //p' | head -n 1)
            [[ -n "${detected}" ]] \
                || die "could not detect the version of ${path} in ${image}."
            [[ -z "${expected}" || "${detected}" == "${expected}" ]] \
                || die "${path} reports ${detected}, but its manifest expects ${expected}."
            printf '%s\n' "${detected}"
            ;;
        sha256)
            digest="$(hash_file "${rootfs}/${path#/}")"
            printf 'sha256:%s\n' "${digest}"
            ;;
        version-sha256)
            digest="$(hash_file "${rootfs}/${path#/}")"
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
    mkdir -p "$(dirname "${destination}")"
    download="$(mktemp "${WORK_ROOT}/standalone-license.XXXXXX")"
    curl -fsSL --retry 3 "${url}" > "${download}" \
        || die "could not download standalone license source ${url}."

    case "${mode}" in
        file)
            mv "${download}" "${destination}"
            ;;
        c-header)
            awk 'NR == 1 && $0 == "/*" { copying = 1 }
                 copying { print }
                 copying && $0 == " */" { exit }' "${download}" > "${destination}"
            rm -f "${download}"
            [[ -s "${destination}" ]] \
                || die "could not extract the license header from ${url}."
            ;;
        *)
            rm -f "${download}"
            die "unknown standalone license mode '${mode}'."
            ;;
    esac
}

collect_standalone_components() {
    local distribution="$1" platform="$2" driver_version="$3" image="$4"
    local rootfs="$5" ownership="$6" license_root="$7" inventory="$8"
    local manifest_distribution path name expected license url license_mode version_mode source
    local version architecture destination coverage

    coverage="${platform} (${driver_version})"
    architecture="${platform#*/}"
    while IFS='|' read -r manifest_distribution path name expected license url license_mode version_mode source; do
        [[ "${manifest_distribution}" == "${distribution}" ]] || continue
        [[ -f "${rootfs}/${path#/}" ]] || continue
        path_is_package_owned "${ownership}" "${path}" && continue

        version="$(detect_standalone_version \
            "${image}" "${platform}" "${path}" "${expected}" "${version_mode}" "${rootfs}")"
        destination="${license_root}/${name}/${version}/${architecture}/upstream/LICENSE"
        download_standalone_license "${url}" "${license_mode}" "${destination}"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${name}" "${version}" standalone "${architecture}" "${license}" "${source}" "${coverage}" \
            >> "${inventory}"
    done < <(standalone_manifest)
}

# Query the installed package database inside the image. This associates each
# path with its package instead of assigning files by a blind filesystem scan.
package_file_query() {
    local distribution="$1"
    if [[ "${distribution}" == rhel* ]]; then
        cat <<'EOF'
# Include a nonzero epoch exactly as Syft does so ownership records match.
rpm -qa --qf '[%{=NAME}\t%|EPOCH?{%{=EPOCH}:}:{}|%{=VERSION}-%{=RELEASE}\t%{=ARCH}\t%{FILENAMES}\t%{FILEFLAGS:fflags}\n]'
EOF
    else
        cat <<'EOF'
# Emit every DPKG-owned path with its package version and architecture.
dpkg-query -W -f='${binary:Package}\n' | while IFS= read -r installed; do
    metadata=$(dpkg-query -W -f='${Package}\t${Version}\t${Architecture}' "$installed")
    dpkg-query -L "$installed" | while IFS= read -r path; do
        printf '%s\t%s\t\n' "$metadata" "$path"
    done
done
EOF
    fi
}

write_selected_image_paths() {
    local distribution="$1" package_keys="$2" ownership="$3" output="$4"
    local name version package_arch path flags manifest_distribution rest
    local unsorted="${output}.unsorted"

    : > "${unsorted}"
    while IFS=$'\t' read -r name version package_arch path flags; do
        [[ -n "${name}" && -n "${version}" && "${path}" == /* ]] || continue
        is_license_path "${path}" "${flags}" || continue
        printf '%s\n' "${path#/}" >> "${unsorted}"
    done < <(filter_inventory_ownership "${package_keys}" "${ownership}")

    while IFS='|' read -r manifest_distribution path rest; do
        [[ "${manifest_distribution}" == "${distribution}" ]] || continue
        printf '%s\n' "${path#/}" >> "${unsorted}"
    done < <(standalone_manifest)

    LC_ALL=C sort -u "${unsorted}" > "${output}"
    rm -f "${unsorted}"
}

extract_complete_rootfs() {
    local image="$1" platform="$2" rootfs="$3"

    CURRENT_CONTAINER="$("${DOCKER}" create --platform "${platform}" "${image}")"
    "${DOCKER}" export "${CURRENT_CONTAINER}" | tar -xf - -C "${rootfs}"
    "${DOCKER}" rm "${CURRENT_CONTAINER}" >/dev/null
    CURRENT_CONTAINER=""
}

# GNU tar in the supported final images streams only selected package-owned
# license files and manifested standalone artifacts. Fall back to docker export
# if an image lacks the required tar behavior.
extract_selected_image_files() {
    local image="$1" platform="$2" paths="$3" rootfs="$4"

    [[ -s "${paths}" ]] || return 0
    CURRENT_CONTAINER="$("${DOCKER}" create \
        --platform "${platform}" \
        --entrypoint tar \
        "${image}" \
        --directory / \
        --create \
        --file - \
        --dereference \
        --ignore-failed-read \
        --no-recursion \
        --files-from /tmp/tpn-paths)"
    "${DOCKER}" cp "${paths}" "${CURRENT_CONTAINER}:/tmp/tpn-paths"

    if ! "${DOCKER}" start -a "${CURRENT_CONTAINER}" | tar -xf - -C "${rootfs}"; then
        log "Selective extraction failed for ${image}; falling back to full rootfs export."
        "${DOCKER}" rm -f "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
        CURRENT_CONTAINER=""
        chmod -R u+w "${rootfs}" 2>/dev/null || true
        rm -rf "${rootfs}"
        mkdir -p "${rootfs}"
        extract_complete_rootfs "${image}" "${platform}" "${rootfs}"
        return
    fi

    "${DOCKER}" rm "${CURRENT_CONTAINER}" >/dev/null
    CURRENT_CONTAINER=""
}

collect_image_licenses() {
    local distribution="$1" platform="$2" image="$3" package_keys="$4" license_root="$5"
    local driver_version="$6" inventory="$7"
    local image_work="${WORK_ROOT}/${distribution}/$(safe_component "${platform}")/$(safe_component "${image}")"
    local rootfs="${image_work}/rootfs" ownership="${image_work}/ownership.tsv"
    local selected_paths="${image_work}/selected-paths.txt"
    local query name version package_arch path flags relative destination suffix

    mkdir -p "${rootfs}"
    query="$(package_file_query "${distribution}")"
    CURRENT_CONTAINER="$("${DOCKER}" create \
        --platform "${platform}" \
        --entrypoint /bin/bash \
        "${image}" -c "${query}")"
    "${DOCKER}" start -a "${CURRENT_CONTAINER}" > "${ownership}"
    "${DOCKER}" rm "${CURRENT_CONTAINER}" >/dev/null
    CURRENT_CONTAINER=""

    if [[ "${TPN_SELECTIVE_EXPORT}" == 1 ]]; then
        write_selected_image_paths "${distribution}" "${package_keys}" "${ownership}" "${selected_paths}"
        extract_selected_image_files "${image}" "${platform}" "${selected_paths}" "${rootfs}"
    else
        extract_complete_rootfs "${image}" "${platform}" "${rootfs}"
    fi

    suffix="$(safe_component "${platform}")"
    while IFS=$'\t' read -r name version package_arch path flags; do
        [[ -n "${name}" && -n "${version}" && "${path}" == /* ]] || continue
        is_license_path "${path}" "${flags}" || continue
        relative="${path#/}"
        destination="${license_root}/${name}/${version}/${package_arch}/${relative}"
        save_license_file "${rootfs}/${relative}" "${destination}" "${suffix}"
    done < <(filter_inventory_ownership "${package_keys}" "${ownership}")

    collect_standalone_components "${distribution}" "${platform}" "${driver_version}" \
        "${image}" "${rootfs}" "${ownership}" "${license_root}" "${inventory}"

    chmod -R u+w "${image_work}"
    rm -rf "${image_work}"
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

# Package caches are normally cleaned from the final image. A disposable
# container downloads the exact installed archive only to recover missing text.
download_missing_archives() {
    local distribution="$1" platform="$2" image="$3" missing="$4" output="$5"
    local command cuda_dist="" cuda_arch=""

    [[ -s "${missing}" ]] || return 0
    mkdir -p "${output}"

    if [[ "${distribution}" == rhel* ]]; then
        command=$(cat <<'EOF'
set -u
mkdir -p /tmp/tpn-packages
(dnf install -y 'dnf-command(download)' || dnf install -y dnf-plugins-core) >/dev/null
while IFS=$(printf '\t') read -r name version package_arch; do
    mkdir -p "/tmp/tpn-packages/$name/$package_arch"
    rpm -q --qf '%{NAME}-%|EPOCH?{%{EPOCH}:}:{}|%{VERSION}-%{RELEASE}.%{ARCH}\n' "$name.$package_arch" 2>/dev/null |
    while IFS= read -r nevra; do
        dnf download --destdir "/tmp/tpn-packages/$name/$package_arch" "$nevra" || true
    done
done < /tmp/tpn-missing.tsv
EOF
)
    else
        if [[ "${distribution}" == "ubuntu26.04" ]]; then
            cuda_dist="ubuntu2604"
            case "${platform#*/}" in
                amd64) cuda_arch="x86_64" ;;
                arm64) cuda_arch="sbsa" ;;
            esac
        fi
        command=$(cat <<'EOF'
set -u
mkdir -p /tmp/tpn-packages
while IFS=$(printf '\t') read -r name version package_arch; do
    mkdir -p "/tmp/tpn-packages/$name/$package_arch"
    find /usr/local/repos -maxdepth 1 -type f -name '*.deb' 2>/dev/null |
    while IFS= read -r archive; do
        archive_name=$(dpkg-deb -f "$archive" Package)
        archive_version=$(dpkg-deb -f "$archive" Version)
        archive_arch=$(dpkg-deb -f "$archive" Architecture)
        if [ "$archive_name" = "$name" ] && [ "$archive_version" = "$version" ] && [ "$archive_arch" = "$package_arch" ]; then
            cp "$archive" "/tmp/tpn-packages/$name/$package_arch/"
        fi
    done
done < /tmp/tpn-missing.tsv

if [ -n "${TPN_CUDA_DIST:-}" ]; then
    echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/${TPN_CUDA_DIST}/${TPN_CUDA_ARCH}/ /" \
        > /etc/apt/sources.list.d/tpn-cuda.list
fi
apt-get update >/dev/null
while IFS=$(printf '\t') read -r name version package_arch; do
    mkdir -p "/tmp/tpn-packages/$name/$package_arch"
    find "/tmp/tpn-packages/$name/$package_arch" -type f -name '*.deb' -print -quit | grep -q . && continue
    (cd "/tmp/tpn-packages/$name/$package_arch" && apt-get download "$name:$package_arch=$version") || true
done < /tmp/tpn-missing.tsv
EOF
)
    fi

    CURRENT_CONTAINER="$("${DOCKER}" create \
        --platform "${platform}" \
        --env "TPN_CUDA_DIST=${cuda_dist}" \
        --env "TPN_CUDA_ARCH=${cuda_arch}" \
        --entrypoint /bin/bash \
        "${image}" -c "${command}")"
    "${DOCKER}" cp "${missing}" "${CURRENT_CONTAINER}:/tmp/tpn-missing.tsv"
    "${DOCKER}" start -a "${CURRENT_CONTAINER}" >/dev/null || true
    "${DOCKER}" cp "${CURRENT_CONTAINER}:/tmp/tpn-packages/." "${output}" 2>/dev/null || true
    "${DOCKER}" rm "${CURRENT_CONTAINER}" >/dev/null
    CURRENT_CONTAINER=""
}

collect_archive_licenses() {
    local distribution="$1" missing="$2" archives="$3" license_root="$4" platform="$5"
    local name version package_arch archive extract path relative suffix
    suffix="archive.$(safe_component "${platform}")"

    while IFS=$'\t' read -r name version package_arch; do
        [[ -d "${archives}/${name}/${package_arch}" ]] || continue
        while IFS= read -r -d '' archive; do
            extract="${WORK_ROOT}/archive-extract/$(safe_component "${distribution}-${name}-${version}-${package_arch}-${RANDOM}")"
            mkdir -p "${extract}"
            case "${archive}" in
                *.rpm)
                    rpm2cpio "${archive}" | (cd "${extract}" && cpio -idm --quiet)
                    ;;
                *.deb)
                    dpkg-deb -x "${archive}" "${extract}"
                    ;;
                *)
                    continue
                    ;;
            esac

            while IFS= read -r -d '' path; do
                relative="${path#${extract}/}"
                is_license_path "/${relative}" "" || continue
                save_license_file "${path}" \
                    "${license_root}/${name}/${version}/${package_arch}/${relative}" "${suffix}"
            done < <(find "${extract}" -type f -print0)
            chmod -R u+w "${extract}"
            rm -rf "${extract}"
        done < <(find "${archives}/${name}/${package_arch}" -type f \( -name '*.rpm' -o -name '*.deb' \) -print0)
    done < "${missing}"
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
        *.gz) gzip -cd "${source}" > "${destination}" ;;
        *.xz) xz -cd "${source}" > "${destination}" ;;
        *.bz2) bzip2 -cd "${source}" > "${destination}" ;;
        *.zst) zstd -qcd "${source}" > "${destination}" ;;
        *) cp "${source}" "${destination}" ;;
    esac
}

emit_index() {
    local index="$1" name version type architecture licenses _ coverage
    printf '| Package | Version | Type | Architecture | License |\n'
    printf '|---------|---------|------|--------------|---------|\n'
    while IFS=$'\t' read -r name version type architecture licenses _ coverage; do
        printf '| `%s` | `%s` | %s | `%s` | %s |\n' \
            "${name}" "${version}" "${type}" "${architecture}" "${licenses}"
    done < "${index}"
}

emit_sections() {
    local index="$1" license_root="$2"
    local name version type architecture licenses _ coverage package_root file relative text fence digest
    local hashes="${WORK_ROOT}/emitted-hashes"

    while IFS=$'\t' read -r name version type architecture licenses _ coverage; do
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
            text="$(mktemp "${WORK_ROOT}/license-text.XXXXXX")"
            materialize_text "${file}" "${text}"
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
    local distribution="$1" driver_version="$2" driver_type="$3" index="$4" license_root="$5"
    local output out_tmp
    case "${driver_type}" in
        vgpu) output="${TPN_OUTPUT_DIR}/vgpu/${distribution}.md" ;;
        vgpu-manager) output="${TPN_OUTPUT_DIR}/vgpu-manager/${driver_version}-${distribution}.md" ;;
        *) output="${TPN_OUTPUT_DIR}/${driver_version}-${distribution}.md" ;;
    esac
    mkdir -p "$(dirname "${output}")"
    out_tmp="$(mktemp "${output}.tmp.XXXXXX")"
    OUT_TEMPS+=("${out_tmp}")

    log "Composing ${output}..."
    {
        printf '# Third-Party Notices\n\n'
        case "${driver_type}" in
            vgpu)
                printf 'NVIDIA vGPU utility support layer for %s\n\n' "${distribution}"
                printf 'This document covers RPM and Debian packages, manifested standalone components, and vendored Go modules present in the inspected DRIVER_TYPE=vgpu final container images for linux/amd64 and linux/arm64. Build-stage-only components are excluded.\n\n'
                printf '**Scope limitation:** A release-specific vGPU/GRID driver `.run` payload must be supplied separately and is not covered by this document. Obtain or generate the notices for that payload before redistributing a complete vGPU image.\n\n'
                ;;
            vgpu-manager)
                printf 'NVIDIA vGPU Manager host container %s for %s\n\n' "${driver_version}" "${distribution}"
                printf 'This document covers RPM and Debian packages present in the inspected vgpu-manager final container image for linux/amd64 and linux/arm64. Build-stage-only components are excluded.\n\n'
                printf '**Scope limitation:** The NVIDIA vGPU Manager `.run` payload is licensed software obtained from the NVIDIA Licensing Portal and is not covered by this document.\n\n'
                ;;
            *)
                printf 'NVIDIA GPU driver container %s for %s\n\n' "${driver_version}" "${distribution}"
                printf 'This document covers RPM and Debian packages plus manifested standalone components present in the inspected DRIVER_TYPE=passthrough final container images for linux/amd64 and linux/arm64. Build-stage-only components are excluded.\n\n'
                ;;
        esac
        printf '## Dependency Index\n\n'
        emit_index "${index}"
        printf '\n## License Texts\n\n'
        emit_sections "${index}" "${license_root}"
    } > "${out_tmp}"

    chmod 644 "${out_tmp}"
    mv "${out_tmp}" "${output}"
}

generate_document() {
    local distribution="$1" driver_version="$2" driver_type="$3"
    local distribution_work="${WORK_ROOT}/${driver_type}-${distribution}-${driver_version}"
    local raw_inventory="${distribution_work}/inventory.tsv"
    local index="${distribution_work}/index.tsv"
    local license_root="${distribution_work}/licenses"
    local package_keys missing archives
    local platform arch image

    mkdir -p "${license_root}"
    : > "${raw_inventory}"

    for platform in "${PLATFORM_LIST[@]}"; do
        arch="${platform#*/}"
        prepare_image "${distribution}" "${platform}" "${driver_version}" "${driver_type}"
        image="${PREPARED_IMAGE}"
        if [[ "${driver_type}" == vgpu ]]; then
            assert_vgpu_payload_absent "${image}" "${platform}"
        fi

        package_keys="${distribution_work}/packages-${arch}-${driver_version}.tsv"
        scan_image "${image}" "${platform}" "${driver_version}" "${raw_inventory}" \
            "${driver_type}" > "${package_keys}"
        [[ -s "${package_keys}" ]] || die "Syft found no RPM/DEB packages in ${image}."

        collect_image_licenses "${distribution}" "${platform}" "${image}" \
            "${package_keys}" "${license_root}" "${driver_version}" "${raw_inventory}"
        if [[ "${driver_type}" == vgpu ]]; then
            collect_vgpu_go_dependencies \
                "${platform}" "${driver_version}" "${license_root}" "${raw_inventory}"
        fi

        missing="${distribution_work}/missing-${arch}-${driver_version}.tsv"
        write_missing_packages "${package_keys}" "${license_root}" "${missing}"
        if [[ -s "${missing}" ]]; then
            archives="${distribution_work}/archives-${arch}-${driver_version}"
            log "Recovering license text from exact package archives for ${image}..."
            download_missing_archives "${distribution}" "${platform}" "${image}" "${missing}" "${archives}"
            collect_archive_licenses "${distribution}" "${missing}" "${archives}" "${license_root}" "${platform}"
            chmod -R u+w "${archives}"
            rm -rf "${archives}"
        fi

        if [[ "${PREPARED_IMAGE_IS_TEMP}" == 1 ]]; then
            "${DOCKER}" image rm -f "${image}" >/dev/null
        fi
    done

    [[ -s "${raw_inventory}" ]] \
        || die "Syft produced no package inventory for ${driver_version}-${distribution}."
    collapse_inventory "${raw_inventory}" > "${index}"

    if cut -f5 "${index}" | LC_ALL=C grep -qE '(^| / )(Unknown|NOASSERTION)( / |$)'; then
        die "Syft reported an unknown license for ${driver_version}-${distribution}."
    fi

    compose_document \
        "${distribution}" "${driver_version}" "${driver_type}" "${index}" "${license_root}"
}

remove_worker_pid() {
    local completed="$1" pid
    local remaining=()
    set +u
    for pid in "${WORKER_PIDS[@]}"; do
        [[ "${pid}" == "${completed}" ]] || remaining+=("${pid}")
    done
    WORKER_PIDS=("${remaining[@]}")
    set -u
}

run_parallel_workers() {
    local distribution driver_version driver_type task pid label failures=0
    local tasks=()
    local pids=() labels=()

    for distribution in "${DISTRIBUTION_LIST[@]}"; do
        for driver_version in "${DRIVER_VERSION_LIST[@]}"; do
            is_excluded_passthrough_combo "${distribution}" "${driver_version}" && continue
            tasks+=("${distribution}|${driver_version}|passthrough")
        done
        if [[ "${TPN_INCLUDE_VGPU}" == 1 ]]; then
            tasks+=("${distribution}|vgpu-util|vgpu")
        fi
    done

    # VGPU_MANAGER_DISTRIBUTION_LIST/VGPU_MANAGER_VERSION_LIST are legitimately
    # empty when vgpu-manager generation isn't requested; bash 3 (macOS's
    # default /bin/bash) treats an empty array expansion as unset under
    # nounset, so this must be guarded the same way cleanup() is.
    set +u
    for distribution in "${VGPU_MANAGER_DISTRIBUTION_LIST[@]}"; do
        for driver_version in "${VGPU_MANAGER_VERSION_LIST[@]}"; do
            tasks+=("${distribution}|${driver_version}|vgpu-manager")
        done
    done
    set -u

    for task in "${tasks[@]}"; do
        IFS='|' read -r distribution driver_version driver_type <<< "${task}"
        label="${driver_version}-${distribution}"
        log "Starting ${label} worker..."
        TPN_WORKER_DISTRIBUTION="${distribution}" \
        TPN_WORKER_DRIVER_VERSION="${driver_version}" \
        TPN_WORKER_DRIVER_TYPE="${driver_type}" TPN_JOBS=1 \
            "${SCRIPT_PATH}" &
        pid=$!
        pids+=("${pid}")
        labels+=("${label}")
        WORKER_PIDS+=("${pid}")

        if (( ${#pids[@]} >= TPN_JOBS )); then
            pid="${pids[0]}"
            label="${labels[0]}"
            if ! wait "${pid}"; then
                log "${label} worker failed."
                failures=1
            fi
            remove_worker_pid "${pid}"
            pids=("${pids[@]:1}")
            labels=("${labels[@]:1}")
        fi
    done

    while (( ${#pids[@]} > 0 )); do
        pid="${pids[0]}"
        label="${labels[0]}"
        if ! wait "${pid}"; then
            log "${label} worker failed."
            failures=1
        fi
        remove_worker_pid "${pid}"
        pids=("${pids[@]:1}")
        labels=("${labels[@]:1}")
    done

    (( failures == 0 )) || die "one or more distribution workers failed."
}

main() {
    check_prerequisites

    if [[ "${TPN_DRY_RUN}" == 1 ]]; then
        local distribution driver_version count=0
        for distribution in "${DISTRIBUTION_LIST[@]}"; do
            for driver_version in "${DRIVER_VERSION_LIST[@]}"; do
                is_excluded_passthrough_combo "${distribution}" "${driver_version}" && continue
                log "[dry-run] ${TPN_OUTPUT_DIR}/${driver_version}-${distribution}.md (passthrough; ${TPN_PLATFORMS})"
                count=$((count + 1))
            done
            if [[ "${TPN_INCLUDE_VGPU}" == 1 ]]; then
                log "[dry-run] ${TPN_OUTPUT_DIR}/vgpu/${distribution}.md (vgpu; ${TPN_PLATFORMS})"
                count=$((count + 1))
            fi
        done
        # See the matching set +u/set -u note in run_parallel_workers.
        set +u
        for distribution in "${VGPU_MANAGER_DISTRIBUTION_LIST[@]}"; do
            for driver_version in "${VGPU_MANAGER_VERSION_LIST[@]}"; do
                log "[dry-run] ${TPN_OUTPUT_DIR}/vgpu-manager/${driver_version}-${distribution}.md (vgpu-manager; ${TPN_PLATFORMS})"
                count=$((count + 1))
            done
        done
        set -u
        log "Validated ${count} planned TPN tasks."
    elif [[ -z "${TPN_WORKER_DISTRIBUTION}" \
        && -z "${TPN_WORKER_DRIVER_VERSION}" \
        && -z "${TPN_WORKER_DRIVER_TYPE}" ]]; then
        run_parallel_workers
    else
        WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gpu-driver-tpn.XXXXXX")"
        generate_document \
            "${DISTRIBUTION_LIST[0]}" \
            "${DRIVER_VERSION_LIST[0]}" \
            "${TPN_WORKER_DRIVER_TYPE:-passthrough}"
    fi
}

main "$@"

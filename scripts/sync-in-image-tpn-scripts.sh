#!/usr/bin/env bash
# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="${1:-sync}"

case "${MODE}" in
    sync|--check) ;;
    *)
        printf 'Usage: %s [sync|--check]\n' "$0" >&2
        exit 2
        ;;
esac

sync_family() {
    local source="$1"
    shift
    local destination

    for destination in "$@"; do
        if [[ "${MODE}" == "--check" ]]; then
            cmp -s "${source}" "${destination}" || {
                printf 'Out of sync: %s (expected an exact copy of %s)\n' \
                    "${destination#${REPO_ROOT}/}" "${source#${REPO_ROOT}/}" >&2
                return 1
            }
        else
            cp "${source}" "${destination}"
        fi
    done
}

sync_family \
    "${SCRIPT_DIR}/generate-in-image-tpn-rhel.sh" \
    "${REPO_ROOT}/rhel8/generate-in-image-tpn.sh" \
    "${REPO_ROOT}/rhel9/generate-in-image-tpn.sh" \
    "${REPO_ROOT}/rhel10/generate-in-image-tpn.sh"

sync_family \
    "${SCRIPT_DIR}/generate-in-image-tpn-ubuntu.sh" \
    "${REPO_ROOT}/ubuntu22.04/generate-in-image-tpn.sh" \
    "${REPO_ROOT}/ubuntu24.04/generate-in-image-tpn.sh" \
    "${REPO_ROOT}/ubuntu26.04/generate-in-image-tpn.sh"

if [[ "${MODE}" == "--check" ]]; then
    printf 'All in-image TPN scripts are synchronized.\n'
else
    printf 'Synchronized in-image TPN scripts from canonical family variants.\n'
fi

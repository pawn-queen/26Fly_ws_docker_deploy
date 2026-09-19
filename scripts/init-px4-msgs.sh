#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command git

destination="${HOST_WS_SRC}/px4_msgs"
runtime_config="${HOST_CONFIG_DIR}/runtime.env"
if [[ ! -r "${runtime_config}" ]]; then
    echo "ERROR: runtime configuration is not readable: ${runtime_config}" >&2
    exit 2
fi
expected_version="$(awk -F= '$1 == "PX4_MSGS_EXPECTED_VERSION" { print $2 }' "${runtime_config}" | tail -n 1)"
expected_commit="$(awk -F= '$1 == "PX4_MSGS_EXPECTED_COMMIT" { print $2 }' "${runtime_config}" | tail -n 1)"

if [[ -z "${expected_version}" || ! "${expected_commit}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: runtime.env must set PX4_MSGS_EXPECTED_VERSION and a full 40-character PX4_MSGS_EXPECTED_COMMIT." >&2
    exit 2
fi
if ! git check-ref-format "refs/tags/${PX4_MSGS_REF}" >/dev/null 2>&1; then
    echo "ERROR: PX4_MSGS_REF must be a valid Git tag name, got '${PX4_MSGS_REF}'." >&2
    exit 2
fi

if [[ ! -d "${HOST_WS_SRC}" ]]; then
    echo "ERROR: workspace source directory is absent: ${HOST_WS_SRC}" >&2
    exit 2
fi

if [[ -L "${destination}" ]]; then
    echo "REFUSED: ${destination} is a symbolic link; it may be outside the mounted source tree." >&2
    exit 3
fi

if [[ -e "${destination}" ]]; then
    if [[ ! -e "${destination}/.git" ]]; then
        echo "REFUSED: ${destination} exists but is not an independent Git checkout or submodule." >&2
        echo "Move the unversioned copy outside ${HOST_WS_SRC}, then run this script again." >&2
        exit 3
    fi
    current_remote="$(git -C "${destination}" remote get-url origin 2>/dev/null || true)"
    if [[ "${current_remote}" != "${PX4_MSGS_REPOSITORY}" ]]; then
        echo "REFUSED: px4_msgs origin is '${current_remote:-unset}', expected '${PX4_MSGS_REPOSITORY}'." >&2
        exit 3
    fi
    if ! px4_msgs_status="$(git -C "${destination}" status --porcelain --untracked-files=all)"; then
        echo "REFUSED: cannot inspect the existing px4_msgs Git checkout." >&2
        exit 3
    fi
    if [[ -n "${px4_msgs_status}" ]]; then
        echo "REFUSED: px4_msgs has local changes or untracked files; preserve or discard them manually first." >&2
        exit 3
    fi
else
    git clone \
        --branch "${PX4_MSGS_REF}" \
        --depth 1 \
        "${PX4_MSGS_REPOSITORY}" \
        "${destination}"
fi

current_commit="$(git -C "${destination}" rev-parse HEAD)"
ref_commit="$(git -C "${destination}" rev-parse "${PX4_MSGS_REF}^{commit}" 2>/dev/null || true)"
if [[ "${ref_commit}" != "${expected_commit}" ]]; then
    git -C "${destination}" fetch --depth 1 origin \
        "refs/tags/${PX4_MSGS_REF}:refs/tags/${PX4_MSGS_REF}"
    ref_commit="$(git -C "${destination}" rev-parse "${PX4_MSGS_REF}^{commit}")"
    if [[ "${ref_commit}" != "${expected_commit}" ]]; then
        echo "REFUSED: ${PX4_MSGS_REF} resolved to ${ref_commit}, expected pinned commit ${expected_commit}." >&2
        exit 3
    fi
fi
if [[ "${current_commit}" != "${expected_commit}" ]]; then
    git -C "${destination}" checkout --detach "${expected_commit}"
    current_commit="$(git -C "${destination}" rev-parse HEAD)"
fi

actual_version="$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "${destination}/package.xml" | head -n 1)"
if [[ -z "${expected_version}" || "${actual_version}" != "${expected_version}" ]]; then
    echo "ERROR: px4_msgs package version is '${actual_version:-unknown}', expected '${expected_version:-unset}'." >&2
    exit 2
fi
if ! px4_msgs_status="$(git -C "${destination}" status --porcelain --untracked-files=all)"; then
    echo "ERROR: cannot inspect px4_msgs after initialization." >&2
    exit 2
fi
if [[ -n "${px4_msgs_status}" ]]; then
    echo "ERROR: px4_msgs is not clean after initialization." >&2
    exit 2
fi

echo "px4_msgs ready: ref=${PX4_MSGS_REF} commit=${current_commit} version=${actual_version}"
echo "Next: ./scripts/build-workspace.sh"

#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

if [[ ! -d /workspace/src ]]; then
    echo "ERROR: /workspace/src is not mounted." >&2
    exit 2
fi

cd /workspace
read -r -a packages <<< "${COLCON_PACKAGES:-px4_msgs detect control}"
available_packages="$(colcon list --base-paths /workspace/src --names-only)"

for package in "${packages[@]}"; do
    if ! grep -Fxq -- "${package}" <<< "${available_packages}"; then
        echo "ERROR: requested ROS package '${package}' is absent below /workspace/src." >&2
        exit 2
    fi
done

px4_msgs_dir=/workspace/src/px4_msgs
actual_px4_msgs_version="$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "${px4_msgs_dir}/package.xml" | head -n 1)"
if [[ -z "${PX4_MSGS_EXPECTED_VERSION:-}" || "${actual_px4_msgs_version}" != "${PX4_MSGS_EXPECTED_VERSION}" ]]; then
    echo "ERROR: px4_msgs version is '${actual_px4_msgs_version:-unknown}', expected '${PX4_MSGS_EXPECTED_VERSION:-unset}'." >&2
    exit 2
fi
if [[ ! -e "${px4_msgs_dir}/.git" ]]; then
    echo "ERROR: px4_msgs is not an independent Git checkout or submodule." >&2
    exit 2
fi
actual_px4_msgs_commit="$(git -c safe.directory="${px4_msgs_dir}" -C "${px4_msgs_dir}" rev-parse HEAD 2>/dev/null || true)"
if [[ -z "${PX4_MSGS_EXPECTED_COMMIT:-}" || "${actual_px4_msgs_commit}" != "${PX4_MSGS_EXPECTED_COMMIT}" ]]; then
    echo "ERROR: px4_msgs commit is '${actual_px4_msgs_commit:-unknown}', expected '${PX4_MSGS_EXPECTED_COMMIT:-unset}'." >&2
    exit 2
fi
if ! px4_msgs_status="$(git --no-optional-locks -c safe.directory="${px4_msgs_dir}" -C "${px4_msgs_dir}" status --porcelain --untracked-files=all)"; then
    echo "ERROR: cannot inspect the px4_msgs Git checkout." >&2
    exit 2
fi
if [[ -n "${px4_msgs_status}" ]]; then
    echo "ERROR: px4_msgs has local changes or untracked files; refusing to build generated interfaces." >&2
    exit 2
fi

jobs="${BUILD_JOBS:-2}"
export CMAKE_BUILD_PARALLEL_LEVEL="${jobs}"
export MAKEFLAGS="-j${jobs}"

echo "Building: ${packages[*]}"
echo "src is read-only; build/install/log are persistent Docker named volumes."

colcon --log-base /workspace/log/colcon build \
    --base-paths /workspace/src \
    --build-base /workspace/build \
    --install-base /workspace/install \
    --symlink-install \
    --executor sequential \
    --event-handlers console_direct+ \
    --packages-select "${packages[@]}" \
    "$@" \
    --cmake-args \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF

marker_tmp=/workspace/install/.26fly-px4-msgs-commit.tmp
printf '%s\n' "${actual_px4_msgs_commit}" > "${marker_tmp}"
mv -f -- "${marker_tmp}" /workspace/install/.26fly-px4-msgs-commit

echo "Build complete. Restart/re-exec an application process to load the overlay."

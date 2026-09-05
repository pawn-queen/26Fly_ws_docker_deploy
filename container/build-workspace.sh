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

echo "Build complete. Restart/re-exec an application process to load the overlay."

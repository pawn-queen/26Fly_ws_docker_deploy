#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"

if ! rosdep db >/dev/null 2>&1; then
    echo "rosdep cache is not initialized for this named HOME." >&2
    echo "Run 'rosdep update --rosdistro ${ROS_DISTRO:-humble}' once with network access, then retry." >&2
    exit 2
fi

# Temporary exceptions mirror known-invalid entries in the current manifests.
# Remove them after package.xml is corrected.
rosdep check \
    --from-paths /workspace/src \
    --ignore-src \
    --rosdistro "${ROS_DISTRO:-humble}" \
    --skip-keys "math time collections test_interface" \
    "$@"

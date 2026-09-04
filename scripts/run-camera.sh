#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"

if [[ -f /workspace/install/local_setup.bash ]]; then
    # shellcheck disable=SC1091
    source /workspace/install/local_setup.bash
fi

if [[ ! -d /dev/bus/usb ]]; then
    echo "ERROR: /dev/bus/usb is not mounted; start the Compose realsense service on the Jetson." >&2
    exit 2
fi

exec ros2 launch realsense2_camera rs_launch.py \
    "align_depth.enable:=${REALSENSE_ALIGN_DEPTH:-true}" \
    "$@"

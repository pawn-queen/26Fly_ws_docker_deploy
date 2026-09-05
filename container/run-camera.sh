#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

if [[ ! -d /dev/bus/usb ]]; then
    echo "ERROR: /dev/bus/usb is absent. Check the host and the /dev:/dev bind mount." >&2
    exit 2
fi

exec ros2 launch realsense2_camera rs_launch.py \
    "align_depth.enable:=${REALSENSE_ALIGN_DEPTH:-true}" \
    "$@"

#!/usr/bin/env bash

# Shared process environment. docker exec does not run the image ENTRYPOINT, so
# every executable sources this file explicitly.
set +u

# shellcheck disable=SC1091
source /opt/ros/humble/setup.bash

if [[ -r /etc/26fly/runtime.env ]]; then
    # This root-owned deployment file is intentionally Bash syntax.
    # shellcheck disable=SC1091
    source /etc/26fly/runtime.env
fi

# These two choices are architectural invariants from 初步方案.md.
export ROS_DISTRO=humble
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_LOCALHOST_ONLY=0
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"
export CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}"
export ROS_HOME=/workspace/log/ros-home
export ROS_LOG_DIR=/workspace/log/ros
export XDG_CACHE_HOME=/workspace/log/cache
export TORCH_HOME=/workspace/log/cache/torch
export YOLO_CONFIG_DIR=/workspace/log/config/ultralytics
export MPLCONFIGDIR=/workspace/log/config/matplotlib

umask 0002
mkdir -p \
    /workspace/build \
    /workspace/install \
    /workspace/log/ros \
    /workspace/log/ros-home \
    /workspace/log/cache/torch \
    /workspace/log/config/ultralytics \
    /workspace/log/config/matplotlib \
    /workspace/log/control/csv \
    /workspace/log/control/photos \
    /workspace/log/control/videos \
    /workspace/log/detect/videos \
    /workspace/log/mavlink

if [[ -f /workspace/install/local_setup.bash ]]; then
    # shellcheck disable=SC1091
    source /workspace/install/local_setup.bash
fi

set -u

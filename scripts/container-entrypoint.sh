#!/usr/bin/env bash
set -e

# ROS-generated setup scripts are not guaranteed to be nounset-safe.
# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"

if [[ -f /workspace/install/local_setup.bash ]]; then
    # shellcheck disable=SC1091
    source /workspace/install/local_setup.bash
fi

umask 0002
mkdir -p \
    /workspace/log/ros \
    /workspace/log/cache/torch \
    /workspace/log/config/ultralytics \
    /workspace/log/config/matplotlib \
    /workspace/log/control/csv \
    /workspace/log/control/photos \
    /workspace/log/control/videos \
    /workspace/log/detect/videos \
    /workspace/log/home/.ros

if (( $# == 0 )); then
    set -- bash
fi

exec "$@"

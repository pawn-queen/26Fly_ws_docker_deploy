#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh
# shellcheck disable=SC1091
source /usr/local/lib/26fly/task-instance.sh
acquire_26fly_task_lock camera

if [[ ! -d /dev/bus/usb ]]; then
    echo "ERROR: /dev/bus/usb is absent. Check the host and the /dev:/dev bind mount." >&2
    exit 2
fi

profile_args=()
target_fps=${REALSENSE_TARGET_FPS:-60}
explicit_profile=false
for argument in "$@"; do
    case "${argument%%:=*}" in
        serial_no|usb_port_id|device_type|config_file|json_file_path|rosbag_filename|\
        rgb_camera.*profile|rgb_camera.*format|depth_module.*profile|depth_module.*format|\
        enable_color|enable_depth|enable_infra*|enable_gyro|enable_accel|enable_sync)
            explicit_profile=true
            ;;
    esac
done
if [[ "$explicit_profile" == true ]]; then
    echo "RealSense: explicit device/profile configuration takes priority; retaining original launch." >&2
elif [[ "$target_fps" != 0 ]]; then
    # This coordinator queries only capabilities and launch argument names,
    # with a shared 3-second deadline. Empty output means unchanged defaults.
    profile_output=""
    if profile_output=$(python3 /usr/local/lib/26fly/select-realsense-profile.py "$target_fps"); then
        if [[ -n "$profile_output" ]]; then
            mapfile -t profile_args <<< "$profile_output"
        fi
    else
        probe_status=$?
        case "$probe_status" in
            129|130|143) exit "$probe_status" ;;
        esac
        echo "RealSense: profile coordinator failed; retaining original launch." >&2
    fi
fi

exec ros2 launch realsense2_camera rs_launch.py \
    "align_depth.enable:=${REALSENSE_ALIGN_DEPTH:-true}" \
    "${profile_args[@]}" \
    "$@"

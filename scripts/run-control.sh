#!/usr/bin/env bash
set -Eeuo pipefail

# Deliberately difficult to enable accidentally. This service can arm and command a real vehicle.
if [[ "${ALLOW_FLIGHT_CONTROL:-NO}" != "YES" ]]; then
    echo "REFUSED: set ALLOW_FLIGHT_CONTROL=YES only after props-off bench checks and source review." >&2
    exit 64
fi

# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"

if [[ ! -f /workspace/install/local_setup.bash ]]; then
    echo "ERROR: workspace is not built. Run: docker compose run --rm workspace build-workspace" >&2
    exit 2
fi
# shellcheck disable=SC1091
source /workspace/install/local_setup.bash

control_main=/workspace/src/fly/control/0821auto.py
servo_source=/workspace/src/fly/control/ServoControl.py
model="${CONTROL_MODEL:-/workspace/src/fly/models/26n_0807_bright_needle.pt}"
camera_device="${WIDE_CAMERA_DEVICE:-/dev/video0}"

for required in "${control_main}" "${servo_source}" "${model}"; do
    if [[ ! -r "${required}" ]]; then
        echo "ERROR: required control input is not readable: ${required}" >&2
        exit 2
    fi
done

# 0821auto.py currently invokes this method during payload release. Starting without it
# would defer an AttributeError until the aircraft is already in the mission.
if ! grep -Eq '^[[:space:]]*def[[:space:]]+publish_dual_actuator_command[[:space:]]*\(' "${servo_source}"; then
    echo "REFUSED: ServoControl.py does not define publish_dual_actuator_command()." >&2
    echo "The current 0821auto.py calls it during release; repair and bench-test the source first." >&2
    exit 65
fi

if [[ ! -c "${camera_device}" || ! -r "${camera_device}" || ! -w "${camera_device}" ]]; then
    echo "ERROR: mapped wide-angle camera is not an accessible character device: ${camera_device}" >&2
    exit 2
fi

# The current Python program selects by v4l2-ctl name rather than accepting a device path.
# Verify that its exact lookup algorithm can resolve the mapped node instead of falling back to 0.
camera_listing="$(v4l2-ctl --list-devices 2>/dev/null || true)"
if ! awk -v hint="${CONTROL_CAMERA_HINT:-imx577}" -v wanted="${camera_device}" '
    /^[^[:space:]]/ { matched = index($0, hint) > 0; next }
    matched {
        device = $0
        sub(/^[[:space:]]+/, "", device)
        if (device == wanted) found = 1
    }
    END { exit(found ? 0 : 1) }
' <<< "${camera_listing}"; then
    echo "REFUSED: camera hint '${CONTROL_CAMERA_HINT:-imx577}' does not resolve to ${camera_device}." >&2
    echo "v4l2-ctl reported:" >&2
    printf '%s\n' "${camera_listing}" >&2
    exit 67
fi

if ! ros2 pkg prefix control >/dev/null 2>&1; then
    echo "ERROR: ROS package 'control' is absent from the install volume; rebuild the workspace." >&2
    exit 2
fi

if [[ "${CONTROL_REQUIRE_PX4_TOPICS:-true}" == "true" ]]; then
    declare -A expected_types=(
        [/fmu/out/vehicle_status_v1]=px4_msgs/msg/VehicleStatus
        [/fmu/out/vehicle_local_position_v1]=px4_msgs/msg/VehicleLocalPosition
    )
    for topic in "${!expected_types[@]}"; do
        actual_type="$(timeout 8s ros2 topic type "${topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
        if [[ "${actual_type}" != "${expected_types[${topic}]}" ]]; then
            echo "REFUSED: ${topic} has type '${actual_type:-<not discovered>}', expected '${expected_types[${topic}]}'." >&2
            echo "Check the XRCE Agent, ROS_DOMAIN_ID, PX4 UXRCE_DDS_DOM_ID and px4_msgs version." >&2
            exit 66
        fi
        if ! timeout 8s ros2 topic echo "${topic}" --once \
            --qos-reliability best_effort \
            --qos-durability transient_local >/dev/null 2>&1; then
            echo "REFUSED: ${topic} was discovered but no compatible sample arrived." >&2
            echo "Inspect 'ros2 topic info -v ${topic}' and the current PX4 vehicle state/QoS." >&2
            exit 66
        fi
    done
fi

mkdir -p \
    /workspace/log/control/csv \
    /workspace/log/control/photos \
    /workspace/log/control/videos

args=(
    --headless
    --model-path "${model}"
    --photo-path /workspace/log/control/photos
    --video-path /workspace/log/control/videos
    --camera-hint "${CONTROL_CAMERA_HINT:-imx577}"
)

if [[ "${CONTROL_RECORD_VIDEO:-false}" == "true" ]]; then
    args+=(--record-video)
fi

# A real console entry is not present in fly/setup.py. Import the explicit live module and
# call main() so its outer __main__ exception-swallowing wrapper is not used.
# Extra command-line arguments can be passed safely as additional argv values.
exec python3 -c 'import importlib; importlib.import_module("control.0821auto").main()' \
    "${args[@]}" "$@"

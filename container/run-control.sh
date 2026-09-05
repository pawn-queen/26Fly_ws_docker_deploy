#!/usr/bin/env bash
set -Eeuo pipefail

# Preserve the one-shot permission passed by docker exec before sourcing the
# persistent config, where it deliberately remains NO.
operator_permission="${ALLOW_FLIGHT_CONTROL:-NO}"
# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

if [[ "${operator_permission}" != "YES" ]]; then
    echo "REFUSED: set ALLOW_FLIGHT_CONTROL=YES for this one manual invocation." >&2
    echo "Only do this after props-off bench checks and source review." >&2
    exit 64
fi
if [[ ! -f /workspace/install/local_setup.bash ]]; then
    echo "ERROR: workspace is not built. Run ./scripts/build-workspace.sh on the host." >&2
    exit 2
fi

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

if ! grep -Eq '^[[:space:]]*def[[:space:]]+publish_dual_actuator_command[[:space:]]*\(' "${servo_source}"; then
    echo "REFUSED: ServoControl.py does not define publish_dual_actuator_command()." >&2
    echo "0821auto.py calls it during payload release; repair and bench-test the source first." >&2
    exit 65
fi

if [[ ! -c "${camera_device}" || ! -r "${camera_device}" || ! -w "${camera_device}" ]]; then
    echo "ERROR: camera is not an accessible character device: ${camera_device}" >&2
    exit 2
fi

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
    printf '%s\n' "${camera_listing}" >&2
    exit 67
fi

if ! ros2 pkg prefix control >/dev/null 2>&1; then
    echo "ERROR: ROS package 'control' is absent from the install volume." >&2
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
            echo "Check Agent status, ROS_DOMAIN_ID, UXRCE_DDS_DOM_ID and px4_msgs compatibility." >&2
            exit 66
        fi
        if ! timeout 8s ros2 topic echo "${topic}" --once \
            --qos-reliability best_effort \
            --qos-durability transient_local >/dev/null 2>&1; then
            echo "REFUSED: ${topic} was discovered but no compatible sample arrived." >&2
            exit 66
        fi
    done
fi

mkdir -p /workspace/log/control/csv /workspace/log/control/photos /workspace/log/control/videos
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

# No real-flight console entry exists in fly/setup.py yet; call the explicit live module.
exec python3 -c 'import importlib; importlib.import_module("control.0821auto").main()' \
    "${args[@]}" "$@"

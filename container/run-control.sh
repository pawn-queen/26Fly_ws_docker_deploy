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
build_marker=/workspace/install/.26fly-px4-msgs-commit
built_px4_msgs_commit=
if [[ -r "${build_marker}" ]]; then
    built_px4_msgs_commit="$(tr -d '[:space:]' < "${build_marker}")"
fi
if [[ -z "${PX4_MSGS_EXPECTED_COMMIT:-}" || "${built_px4_msgs_commit}" != "${PX4_MSGS_EXPECTED_COMMIT}" ]]; then
    echo "REFUSED: install volume px4_msgs marker is '${built_px4_msgs_commit:-missing}', expected '${PX4_MSGS_EXPECTED_COMMIT:-unset}'." >&2
    echo "Run ./scripts/build-workspace.sh before flight control." >&2
    exit 2
fi

control_main=/workspace/src/fly/control/0821auto.py
servo_source=/workspace/src/fly/control/ServoControl.py
model="${CONTROL_MODEL:-/workspace/src/fly/models/26fly_jetson.engine}"
camera_device="${WIDE_CAMERA_DEVICE:-/dev/video0}"

for required in "${control_main}" "${servo_source}" "${model}"; do
    if [[ ! -r "${required}" ]]; then
        echo "ERROR: required control input is not readable: ${required}" >&2
        exit 2
    fi
done
if [[ "${model}" != *.engine ]]; then
    echo "REFUSED: control model must be a Jetson TensorRT .engine file: ${model}" >&2
    exit 2
fi

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
    matched && !seen {
        device = $0
        sub(/^[[:space:]]+/, "", device)
        if (device ~ /^\/dev\/video[0-9]+$/) {
            first = device
            seen = 1
        }
    }
    END { exit(seen && first == wanted ? 0 : 1) }
' <<< "${camera_listing}"; then
    echo "REFUSED: camera hint '${CONTROL_CAMERA_HINT:-imx577}' does not select ${camera_device} as its first video node." >&2
    printf '%s\n' "${camera_listing}" >&2
    exit 67
fi
if ! v4l2-ctl --device "${camera_device}" --list-formats-ext >/dev/null 2>&1; then
    echo "REFUSED: ${camera_device} does not expose usable V4L2 capture formats." >&2
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
        [/fmu/out/vehicle_odometry]=px4_msgs/msg/VehicleOdometry
    )
    for topic in "${!expected_types[@]}"; do
        actual_type="$(timeout 8s ros2 topic type "${topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
        if [[ "${actual_type}" != "${expected_types[${topic}]}" ]]; then
            echo "REFUSED: ${topic} has type '${actual_type:-<not discovered>}', expected '${expected_types[${topic}]}'." >&2
            echo "Check Agent status, ROS_DOMAIN_ID, UXRCE_DDS_DOM_ID and px4_msgs compatibility." >&2
            exit 66
        fi
        if ! timeout 8s ros2 topic echo "${topic}" --once \
            --no-daemon --spin-time 3 \
            --qos-reliability best_effort \
            --qos-durability transient_local >/dev/null 2>&1; then
            echo "REFUSED: ${topic} was discovered but no compatible sample arrived." >&2
            exit 66
        fi
    done

    # This is a graph-level sanity check for compatible readers. Actual PX4
    # command acceptance must still be confirmed from VehicleCommandAck during
    # the props-off bench test.
    declare -A expected_input_types=(
        [/fmu/in/offboard_control_mode]=px4_msgs/msg/OffboardControlMode
        [/fmu/in/trajectory_setpoint]=px4_msgs/msg/TrajectorySetpoint
        [/fmu/in/vehicle_command]=px4_msgs/msg/VehicleCommand
    )
    for topic in "${!expected_input_types[@]}"; do
        actual_type="$(timeout 8s ros2 topic type "${topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
        if [[ "${actual_type}" != "${expected_input_types[${topic}]}" ]]; then
            echo "REFUSED: ${topic} has type '${actual_type:-<not discovered>}', expected '${expected_input_types[${topic}]}'." >&2
            exit 66
        fi
        topic_info="$(timeout 8s ros2 topic info "${topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
        subscription_count="$(awk '/^Subscription count:/ { print $3 }' <<< "${topic_info}")"
        if ! [[ "${subscription_count}" =~ ^[1-9][0-9]*$ ]]; then
            echo "REFUSED: ${topic} has no discovered compatible subscription." >&2
            printf '%s\n' "${topic_info}" >&2
            exit 66
        fi
    done

    ack_type="$(timeout 8s ros2 topic type /fmu/out/vehicle_command_ack --no-daemon --spin-time 3 2>/dev/null || true)"
    if [[ "${ack_type}" != "px4_msgs/msg/VehicleCommandAck" ]]; then
        echo "REFUSED: /fmu/out/vehicle_command_ack is not available with the expected type." >&2
        exit 66
    fi
fi

if [[ "${CONTROL_REQUIRE_VISION_TOPICS:-true}" == "true" ]]; then
    declare -A expected_camera_types=(
        ["${DETECT_COLOR_TOPIC:-/camera/camera/color/image_raw}"]=sensor_msgs/msg/Image
        ["${DETECT_DEPTH_TOPIC:-/camera/camera/aligned_depth_to_color/image_raw}"]=sensor_msgs/msg/Image
        ["${DETECT_CAMERA_INFO_TOPIC:-/camera/camera/color/camera_info}"]=sensor_msgs/msg/CameraInfo
    )
    for topic in "${!expected_camera_types[@]}"; do
        actual_type="$(timeout 8s ros2 topic type "${topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
        if [[ "${actual_type}" != "${expected_camera_types[${topic}]}" ]]; then
            echo "REFUSED: camera topic ${topic} has type '${actual_type:-<not discovered>}', expected '${expected_camera_types[${topic}]}'." >&2
            exit 68
        fi
        topic_info="$(timeout 8s ros2 topic info "${topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
        publisher_count="$(awk '/^Publisher count:/ { print $3 }' <<< "${topic_info}")"
        if ! [[ "${publisher_count}" =~ ^[1-9][0-9]*$ ]]; then
            echo "REFUSED: camera topic ${topic} has no publisher." >&2
            exit 68
        fi
        if ! timeout 8s ros2 topic echo "${topic}" --once \
            --no-daemon --spin-time 3 \
            --qos-reliability best_effort \
            --qos-durability volatile >/dev/null 2>&1; then
            echo "REFUSED: camera topic ${topic} was discovered but no recent sample arrived." >&2
            exit 68
        fi
    done

    observation_topic=/target_observation
    observation_type="$(timeout 8s ros2 topic type "${observation_topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
    if [[ "${observation_type}" != "sensor_msgs/msg/PointCloud" ]]; then
        echo "REFUSED: ${observation_topic} has type '${observation_type:-<not discovered>}', expected sensor_msgs/msg/PointCloud." >&2
        exit 68
    fi
    observation_info="$(timeout 8s ros2 topic info -v "${observation_topic}" --no-daemon --spin-time 3 2>/dev/null || true)"
    observation_publishers="$(awk '/^Publisher count:/ { print $3 }' <<< "${observation_info}")"
    if ! [[ "${observation_publishers}" =~ ^[1-9][0-9]*$ ]] || \
        ! grep -Eq '^[[:space:]]*Node name:[[:space:]]+yolov5_ros2[[:space:]]*$' <<< "${observation_info}"; then
        echo "REFUSED: ${observation_topic} is not published by the expected yolov5_ros2 detector." >&2
        printf '%s\n' "${observation_info}" >&2
        exit 68
    fi
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

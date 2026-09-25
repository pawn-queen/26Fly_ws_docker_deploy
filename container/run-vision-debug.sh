#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

mode=run
if [[ "${1:-}" == "--stop" ]]; then
    mode=stop
    shift
fi
if (( $# > 1 )); then
    echo "ERROR: usage: run-vision-debug [--stop] [session-id]" >&2
    exit 64
fi

session_id="${1:-manual}"
if [[ ! "${session_id}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: invalid debug session id: ${session_id}" >&2
    exit 2
fi
state_dir=/run/lock/26fly-vision-debug
state_file="${state_dir}/${session_id}.pid"

process_matches_session() {
    local pid=$1
    local expected_session=$2
    local argument
    local found_runner=false
    local found_session=false

    if ! [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || [[ ! -r "/proc/${pid}/cmdline" ]]; then
        return 1
    fi
    while IFS= read -r argument; do
        if [[ "${argument}" == "/usr/local/bin/run-vision-debug" ]]; then
            found_runner=true
        elif [[ "${argument}" == "${expected_session}" ]]; then
            found_session=true
        fi
    done < <(tr '\0' '\n' < "/proc/${pid}/cmdline")
    [[ "${found_runner}" == "true" && "${found_session}" == "true" ]]
}

stop_session() {
    local pid extra
    local deadline

    if [[ ! -f "${state_file}" || -L "${state_file}" ]]; then
        return 4
    fi
    read -r pid extra < "${state_file}" || return 4
    if [[ -n "${extra:-}" ]] || ! process_matches_session "${pid:-}" "${session_id}"; then
        rm -f -- "${state_file}"
        return 4
    fi

    echo "Stopping vision debug session ${session_id} (pid=${pid})..." >&2
    kill -TERM "${pid}" 2>/dev/null || true
    deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        if ! process_matches_session "${pid}" "${session_id}"; then
            return 0
        fi
        sleep 0.1
    done
    echo "ERROR: vision debug session ${session_id} did not stop within 10 seconds." >&2
    return 1
}

if [[ "${mode}" == "stop" ]]; then
    stop_session
    exit $?
fi

if [[ -z "${DISPLAY:-}" || -z "${XAUTHORITY:-}" || ! -r "${XAUTHORITY}" ]]; then
    echo "ERROR: DISPLAY/XAUTHORITY was not prepared by the host debug wrapper." >&2
    exit 2
fi
if [[ ! -f /workspace/install/local_setup.bash ]]; then
    echo "ERROR: workspace is not built. Run ./scripts/build-workspace.sh on the host." >&2
    exit 2
fi
if ! command -v vision-debug-viewer >/dev/null 2>&1; then
    echo "ERROR: vision-debug-viewer is absent; rebuild the image and migrate the container." >&2
    exit 2
fi

exec 9>/run/lock/26fly-vision-debug.lock
if ! flock -n 9; then
    echo "REFUSED: another 26Fly vision debug session is already active." >&2
    exit 3
fi

declare -a child_pids=()
started_pid=

process_group_is_alive() {
    kill -0 -- "-$1" 2>/dev/null
}

cleanup() {
    local pid deadline any_alive state_pid state_extra
    trap - EXIT INT TERM HUP
    for pid in "${child_pids[@]}"; do
        if process_group_is_alive "${pid}"; then
            kill -TERM -- "-${pid}" 2>/dev/null || true
        fi
    done

    deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        any_alive=false
        for pid in "${child_pids[@]}"; do
            if process_group_is_alive "${pid}"; then
                any_alive=true
                break
            fi
        done
        if [[ "${any_alive}" == "false" ]]; then
            break
        fi
        sleep 0.1
    done

    for pid in "${child_pids[@]}"; do
        if process_group_is_alive "${pid}"; then
            kill -KILL -- "-${pid}" 2>/dev/null || true
        fi
        wait "${pid}" 2>/dev/null || true
    done
    if [[ -f "${state_file}" && ! -L "${state_file}" ]]; then
        read -r state_pid state_extra < "${state_file}" || true
        if [[ "${state_pid:-}" == "$$" && -z "${state_extra:-}" ]]; then
            rm -f -- "${state_file}"
        fi
    fi
    rm -f -- "${state_file}.tmp.$$"
    if [[ "${XAUTHORITY:-}" == /run/26fly-xauthority.* ]]; then
        rm -f -- "${XAUTHORITY}" || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

mkdir -p -- "${state_dir}"
(umask 077; printf '%s\n' "$$" > "${state_file}.tmp.$$")
mv -f -- "${state_file}.tmp.$$" "${state_file}"

existing_nodes="$(timeout 5s ros2 node list 2>/dev/null || true)"
for forbidden_node in /camera/camera /yolov5_ros2 /offboard_control_takeoff_and_land; do
    if grep -Fxq -- "${forbidden_node}" <<< "${existing_nodes}"; then
        echo "REFUSED: ROS node already exists: ${forbidden_node}" >&2
        echo "Stop the existing camera/detect/control process before starting the debug stack." >&2
        exit 3
    fi
done

process_conflicts="$({
    pgrep -a -f 'ros2 launch realsense2_camera|realsense2_camera_node|ros2 run detect detect|/install/detect/lib/detect/detect|detect[.]detect_ros|control[.]0821auto' || true
} 2>/dev/null)"
if [[ -n "${process_conflicts}" ]]; then
    echo "REFUSED: an existing camera, detector, or control process may own this stack:" >&2
    printf '%s\n' "${process_conflicts}" >&2
    exit 3
fi

if ! timeout --signal=TERM --kill-after=2s 8s vision-debug-viewer --probe-gui; then
    echo "ERROR: the container cannot open a window in DISPLAY=${DISPLAY}." >&2
    exit 2
fi

start_component() {
    local pgid=
    setsid "$@" 9>&- &
    started_pid=$!
    for _ in {1..20}; do
        pgid="$(ps -o pgid= -p "${started_pid}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${pgid}" == "${started_pid}" ]]; then
            child_pids+=("${started_pid}")
            return 0
        fi
        if ! kill -0 "${started_pid}" 2>/dev/null; then
            wait "${started_pid}" 2>/dev/null || true
            echo "ERROR: component exited before its isolated process group was ready: $*" >&2
            return 1
        fi
        sleep 0.05
    done
    kill -TERM "${started_pid}" 2>/dev/null || true
    wait "${started_pid}" 2>/dev/null || true
    echo "ERROR: could not isolate component in a dedicated process group: $*" >&2
    return 1
}

wait_for_topic_sample() {
    local topic=$1
    local watched_pid=$2
    local deadline=$3
    while (( SECONDS < deadline )); do
        if ! process_group_is_alive "${watched_pid}"; then
            echo "ERROR: camera exited while waiting for ${topic}." >&2
            return 1
        fi
        if timeout 3s ros2 topic echo "${topic}" --once \
            --no-daemon --spin-time 1 \
            --qos-reliability best_effort \
            --qos-durability volatile >/dev/null 2>&1; then
            echo "Camera sample ready: ${topic}"
            return 0
        fi
    done
    echo "ERROR: timed out waiting for a sample on ${topic}." >&2
    return 1
}

wait_for_observation_publisher() {
    local watched_pid=$1
    local deadline=$2
    local topic_info publisher_count
    while (( SECONDS < deadline )); do
        if ! process_group_is_alive "${watched_pid}"; then
            echo "ERROR: detector exited before /target_observation became ready." >&2
            return 1
        fi
        topic_info="$(timeout 3s ros2 topic info /target_observation \
            --no-daemon --spin-time 1 2>/dev/null || true)"
        publisher_count="$(awk '/^Publisher count:/ { print $3 }' <<< "${topic_info}")"
        if [[ "${publisher_count}" =~ ^[1-9][0-9]*$ ]]; then
            echo "Detector publisher ready: /target_observation"
            return 0
        fi
        sleep 0.25
    done
    echo "ERROR: timed out waiting for the detector publisher." >&2
    return 1
}

echo "[1/3] Starting RealSense (this debug stack does not start or preview the IMX577 wide camera)..."
start_component run-camera
camera_pid="${started_pid}"

camera_deadline=$((SECONDS + 60))
wait_for_topic_sample "${DETECT_COLOR_TOPIC:-/camera/camera/color/image_raw}" \
    "${camera_pid}" "${camera_deadline}"
wait_for_topic_sample "${DETECT_DEPTH_TOPIC:-/camera/camera/aligned_depth_to_color/image_raw}" \
    "${camera_pid}" "${camera_deadline}"
wait_for_topic_sample "${DETECT_CAMERA_INFO_TOPIC:-/camera/camera/color/camera_info}" \
    "${camera_pid}" "${camera_deadline}"

echo "[2/3] Starting headless detector..."
start_component run-detect
detect_pid="${started_pid}"
wait_for_observation_publisher "${detect_pid}" "$((SECONDS + 45))"

echo "[3/3] Starting decoupled debug viewer..."
start_component vision-debug-viewer --ros-args \
    -p "color_topic:=${DETECT_COLOR_TOPIC:-/camera/camera/color/image_raw}" \
    -p "depth_topic:=${DETECT_DEPTH_TOPIC:-/camera/camera/aligned_depth_to_color/image_raw}" \
    -p "camera_info_topic:=${DETECT_CAMERA_INFO_TOPIC:-/camera/camera/color/camera_info}" \
    -p "observation_topic:=/target_observation"

echo "Vision debug is running in DISPLAY=${DISPLAY}. Press q/Esc in the window or Ctrl-C here to stop."
set +e
wait -n "${child_pids[@]}"
component_status=$?
set -e
if (( component_status != 0 )); then
    echo "ERROR: a debug-stack component exited with status ${component_status}." >&2
else
    echo "A debug-stack component exited; stopping the remaining components."
fi
exit "${component_status}"

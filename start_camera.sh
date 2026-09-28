#!/usr/bin/env bash
set -Eeuo pipefail

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${deploy_dir}/scripts/lib/runtime.sh"

if (( $# != 0 )); then
    echo "ERROR: start_camera.sh does not accept arguments; configure the services in config/runtime.env." >&2
    exit 64
fi

load_runtime_settings

camera_pid=
detect_pid=

job_is_running() {
    local expected_pid=$1 running_pid
    while IFS= read -r running_pid; do
        [[ "${running_pid}" == "${expected_pid}" ]] && return 0
    done < <(jobs -pr)
    return 1
}

cleanup() {
    local original_status=$?
    trap - EXIT
    trap '' INT TERM HUP

    # The existing wrappers own their units and verify that systemctl stop
    # completed. Signal only wrappers launched by this script.
    if [[ -n "${detect_pid}" ]] && job_is_running "${detect_pid}"; then
        kill -TERM "${detect_pid}" 2>/dev/null || true
    fi
    if [[ -n "${camera_pid}" ]] && job_is_running "${camera_pid}"; then
        kill -TERM "${camera_pid}" 2>/dev/null || true
    fi
    if [[ -n "${detect_pid}" ]]; then
        wait "${detect_pid}" 2>/dev/null || true
    fi
    if [[ -n "${camera_pid}" ]]; then
        wait "${camera_pid}" 2>/dev/null || true
    fi
    return "${original_status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ensure_runtime_running

probe_camera_sample() {
    local topic=$1
    docker exec "${CONTAINER_NAME}" bash -c '
        source /usr/local/lib/26fly/env.sh
        exec timeout 3s ros2 topic echo "$1" --once \
            --no-daemon --spin-time 1 \
            --qos-reliability best_effort \
            --qos-durability volatile
    ' bash "${topic}" >/dev/null 2>&1
}

wait_for_camera_sample() {
    local topic=$1 deadline=$2
    while (( SECONDS < deadline )); do
        if ! job_is_running "${camera_pid}"; then
            echo "ERROR: camera wrapper exited before ${topic} produced a sample." >&2
            return 1
        fi
        if probe_camera_sample "${topic}"; then
            echo "Camera sample ready: ${topic}"
            return 0
        fi
        sleep 0.25
    done
    echo "ERROR: timed out waiting for a camera sample on ${topic}." >&2
    return 1
}

probe_detect_publisher() {
    local topic_info publisher_count
    if ! topic_info="$(docker exec "${CONTAINER_NAME}" bash -c '
        source /usr/local/lib/26fly/env.sh
        exec timeout 3s ros2 topic info /target_observation \
            --no-daemon --spin-time 1
    ' 2>/dev/null)"; then
        return 1
    fi
    publisher_count="$(awk '/^Publisher count:/ { print $3 }' <<< "${topic_info}")"
    [[ "${publisher_count}" =~ ^[1-9][0-9]*$ ]]
}

wait_for_detect_publisher() {
    local deadline=$1
    while (( SECONDS < deadline )); do
        if ! job_is_running "${camera_pid}"; then
            echo "ERROR: camera wrapper exited while waiting for the detector." >&2
            return 1
        fi
        if ! job_is_running "${detect_pid}"; then
            echo "ERROR: detect wrapper exited before /target_observation had a publisher." >&2
            return 1
        fi
        if probe_detect_publisher; then
            echo "Detector publisher ready: /target_observation"
            return 0
        fi
        sleep 0.25
    done
    echo "ERROR: timed out waiting for the detector publisher." >&2
    return 1
}

echo "Starting camera first; waiting for RGB, aligned depth, and camera info samples..."
"${deploy_dir}/scripts/run-camera.sh" &
camera_pid=$!

# One shared deadline for all three camera topics. Startup races are retried,
# but a missing camera cannot leave the stack waiting forever.
camera_deadline=$((SECONDS + 90))
wait_for_camera_sample "${DETECT_COLOR_TOPIC:-/camera/camera/color/image_raw}" "${camera_deadline}"
wait_for_camera_sample "${DETECT_DEPTH_TOPIC:-/camera/camera/aligned_depth_to_color/image_raw}" "${camera_deadline}"
wait_for_camera_sample "${DETECT_CAMERA_INFO_TOPIC:-/camera/camera/color/camera_info}" "${camera_deadline}"

if ! job_is_running "${camera_pid}"; then
    echo "ERROR: camera wrapper exited before the detector could start." >&2
    exit 1
fi

echo "Camera is publishing samples; starting detector..."
"${deploy_dir}/scripts/run-detect.sh" &
detect_pid=$!
wait_for_detect_publisher "$((SECONDS + 60))"

echo "Camera and detector are running. Press Ctrl-C to stop both."
while true; do
    if ! job_is_running "${camera_pid}"; then
        echo "Camera wrapper exited; stopping detector." >&2
        if wait "${camera_pid}"; then exit 0; else exit "$?"; fi
    fi
    if ! job_is_running "${detect_pid}"; then
        echo "Detector wrapper exited; stopping camera." >&2
        if wait "${detect_pid}"; then exit 0; else exit "$?"; fi
    fi
    sleep 0.25
done

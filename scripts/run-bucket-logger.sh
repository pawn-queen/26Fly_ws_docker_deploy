#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo 'Usage: ./scripts/run-bucket-logger.sh [logger options]'
    echo 'Start collection; press y to mark a stable observation, Ctrl-C to stop.'
    python3 "$(dirname -- "${BASH_SOURCE[0]}")/log_bucket_ned.py" --help
    exit 0
fi

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
"${DEPLOY_DIR}/scripts/deploy-bucket-logger.sh"

camera_pid=
cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "${camera_pid}" ]]; then
        kill -TERM "${camera_pid}" 2>/dev/null || true
        wait "${camera_pid}" 2>/dev/null || true
    fi
    return "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Reuse an already-running camera; the existing wrapper owns any camera started here.
if ! docker exec "${CONTAINER_NAME}" systemctl is-active --quiet 26fly-camera.service; then
    "${DEPLOY_DIR}/scripts/run-camera.sh" >&2 &
    camera_pid=$!
fi

tty_args=(-i)
if [[ -t 0 && -t 1 ]]; then
    tty_args=(-it)
fi

docker exec "${tty_args[@]}" "${CONTAINER_NAME}" bash -c '
    set -Eeuo pipefail
    source /usr/local/lib/26fly/env.sh
    mkdir -p /run/lock/26fly /workspace/log/calibration
    exec 9>/run/lock/26fly/bucket-logger.lock
    if ! flock -n 9; then
        echo "ERROR: bucket logger is already running." >&2
        exit 3
    fi
    logfile="/workspace/log/calibration/bucket_$(date +%Y%m%d_%H%M%S)_$$.jsonl"
    exec python3 -u /workspace/log/calibration/bin/log_bucket_ned.py \
        --weights "${DETECT_MODEL:-/workspace/src/detect/models/26fly_jetson.engine}" \
        --conf "${DETECT_CONFIDENCE:-0.4}" \
        --color-topic "${DETECT_COLOR_TOPIC:-/camera/camera/color/image_raw}" \
        --depth-topic "${DETECT_DEPTH_TOPIC:-/camera/camera/aligned_depth_to_color/image_raw}" \
        --camera-info-topic "${DETECT_CAMERA_INFO_TOPIC:-/camera/camera/color/camera_info}" \
        --output "${logfile}" "$@"
' bash "$@"

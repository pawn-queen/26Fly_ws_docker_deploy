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
# shellcheck disable=SC1091
source /usr/local/lib/26fly/task-instance.sh
acquire_26fly_task_lock control

model="${CONTROL_MODEL:-/workspace/src/fly/models/26fly_jetson.engine}"
camera_device="${WIDE_CAMERA_DEVICE:-/dev/video0}"

mkdir -p /workspace/log/control/csv /workspace/log/control/photos /workspace/log/control/videos
args=(
    --headless
    --model-path "${model}"
    --photo-path /workspace/log/control/photos
    --video-path /workspace/log/control/videos
    --camera-hint "${CONTROL_CAMERA_HINT:-imx577}"
    --camera-device "${camera_device}"
)
if [[ "${CONTROL_RECORD_VIDEO:-false}" == "true" ]]; then
    args+=(--record-video)
fi

# No real-flight console entry exists in fly/setup.py yet; call the explicit live module.
exec python3 -c 'import importlib; importlib.import_module("control.0821auto").main()' \
    "${args[@]}" "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh
# shellcheck disable=SC1091
source /usr/local/lib/26fly/task-instance.sh
acquire_26fly_task_lock detect

if [[ ! -f /workspace/install/local_setup.bash ]]; then
    echo "ERROR: workspace is not built. Run ./scripts/build-workspace.sh on the host." >&2
    exit 2
fi

model="${DETECT_MODEL:-/workspace/src/detect/models/26fly_jetson.engine}"
if [[ ! -r "${model}" ]]; then
    echo "ERROR: detection model is not readable: ${model}" >&2
    exit 2
fi
if [[ "${model}" != *.engine ]]; then
    echo "ERROR: detection model must be a Jetson TensorRT .engine file: ${model}" >&2
    exit 2
fi
if ! ros2 pkg prefix detect >/dev/null 2>&1; then
    echo "ERROR: ROS package 'detect' is absent from the install volume." >&2
    exit 2
fi

mkdir -p /workspace/log/detect/videos
# ROS double parameters require floating YAML even when the env value is an
# integer such as 60.  Normalize without interpreting any value as shell code.
rate_text="$(python3 - \
    "${DETECT_MAX_PROCESSING_HZ:-60}" \
    "${DETECT_DEBUG_IMAGE_HZ:-30}" \
    "${DETECT_RECORD_FPS:-15}" <<'PY'
import math
import sys

names = ('DETECT_MAX_PROCESSING_HZ', 'DETECT_DEBUG_IMAGE_HZ', 'DETECT_RECORD_FPS')
for name, raw in zip(names, sys.argv[1:]):
    try:
        value = float(raw)
    except ValueError:
        sys.exit('ERROR: %s must be positive and finite' % name)
    if not math.isfinite(value) or value <= 0:
        sys.exit('ERROR: %s must be positive and finite' % name)
    print(repr(value))
PY
)"
mapfile -t detect_rates <<<"${rate_text}"
exec ros2 run detect detect --ros-args \
    -p "weights_path:=${model}" \
    -p "conf_threshold:=${DETECT_CONFIDENCE:-0.4}" \
    -p "color_topic:=${DETECT_COLOR_TOPIC:-/camera/camera/color/image_raw}" \
    -p "depth_topic:=${DETECT_DEPTH_TOPIC:-/camera/camera/aligned_depth_to_color/image_raw}" \
    -p "camera_info_topic:=${DETECT_CAMERA_INFO_TOPIC:-/camera/camera/color/camera_info}" \
    -p "show_image:=false" \
    -p "record_rgb_video:=${DETECT_RECORD_VIDEO:-false}" \
    -p "video_output_path:=/workspace/log/detect/videos" \
    -p "publish_legacy_target_position:=${DETECT_PUBLISH_LEGACY_TARGET:-false}" \
    -p "max_processing_hz:=${detect_rates[0]}" \
    -p "debug_image_hz:=${detect_rates[1]}" \
    -p "recording_fps:=${detect_rates[2]}" \
    "$@"

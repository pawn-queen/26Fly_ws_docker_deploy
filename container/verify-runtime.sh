#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

pid1="$(ps -p 1 -o comm= | tr -d '[:space:]')"
if [[ "${pid1}" != "systemd" ]]; then
    echo "ERROR: expected container PID 1 to be systemd, got '${pid1}'." >&2
    exit 2
fi

resolve_required_serial() {
    local label=$1
    local transport=$2
    local device=$3
    if [[ "${transport}" != "serial" ]]; then
        return 0
    fi
    if [[ -z "${device}" || ! -c "${device}" || ! -r "${device}" || ! -w "${device}" ]]; then
        echo "ERROR: ${label} serial device is not accessible: ${device:-<unset>}" >&2
        exit 2
    fi
    readlink -f -- "${device}"
}

xrce_device_real="$(resolve_required_serial XRCE "${XRCE_TRANSPORT:-serial}" "${XRCE_SERIAL_DEVICE:-}")"
mavlink_device_real="$(resolve_required_serial MAVLink "${MAVLINK_TRANSPORT:-serial}" "${MAVLINK_SERIAL_DEVICE:-}")"
if [[ -n "${xrce_device_real}" && "${xrce_device_real}" == "${mavlink_device_real}" ]]; then
    echo "ERROR: XRCE and MAVLink resolve to the same device: ${xrce_device_real}" >&2
    exit 2
fi

systemctl is-active --quiet 26fly.target
declare -A expected_service_executable=(
    [micro-xrce-agent.service]=MicroXRCEAgent
    [mavlink-routerd.service]=mavlink-routerd
)
declare -A service_serial_device=(
    [micro-xrce-agent.service]="${xrce_device_real}"
    [mavlink-routerd.service]="${mavlink_device_real}"
)
for service in micro-xrce-agent.service mavlink-routerd.service; do
    if [[ "$(systemctl is-enabled "${service}")" != "enabled" ]]; then
        echo "ERROR: ${service} is not enabled in 26fly.target." >&2
        exit 2
    fi
    if [[ "$(systemctl show --property=Restart --value "${service}")" != "always" ]]; then
        echo "ERROR: ${service} does not use Restart=always." >&2
        exit 2
    fi
    if ! systemctl is-active --quiet "${service}"; then
        echo "ERROR: ${service} is not active; inspect docker logs for its selected device." >&2
        exit 2
    fi
    main_pid="$(systemctl show --property=MainPID --value "${service}")"
    if ! [[ "${main_pid}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ${service} has no live MainPID." >&2
        exit 2
    fi
    main_executable="$(readlink -f -- "/proc/${main_pid}/exe" 2>/dev/null || true)"
    if [[ "$(basename -- "${main_executable}")" != "${expected_service_executable[${service}]}" ]]; then
        echo "ERROR: ${service} is still in a wrapper/restart state; MainPID executable is '${main_executable:-unknown}'." >&2
        exit 2
    fi
    serial_device="${service_serial_device[${service}]}"
    if [[ -n "${serial_device}" ]]; then
        device_is_open=false
        for descriptor in "/proc/${main_pid}/fd/"*; do
            if [[ "$(readlink -f -- "${descriptor}" 2>/dev/null || true)" == "${serial_device}" ]]; then
                device_is_open=true
                break
            fi
        done
        if [[ "${device_is_open}" != "true" ]]; then
            echo "ERROR: ${service} is not holding configured serial device ${serial_device}." >&2
            exit 2
        fi
    fi
    echo "Service ready: ${service} pid=${main_pid} executable=${main_executable} device=${serial_device:-network}"
done

[[ "${RMW_IMPLEMENTATION}" == "rmw_fastrtps_cpp" ]]
command -v MicroXRCEAgent >/dev/null
command -v mavlink-routerd >/dev/null
command -v flock >/dev/null
command -v setsid >/dev/null
command -v run-vision-debug >/dev/null
command -v vision-debug-viewer >/dev/null
command -v xauth >/dev/null

viewer_executable="$(command -v vision-debug-viewer)"
viewer_linkage="$(ldd "${viewer_executable}")"
if grep 'not found' <<<"${viewer_linkage}" >/dev/null; then
    echo "ERROR: vision-debug-viewer has unresolved shared-library dependencies." >&2
    echo "${viewer_linkage}" >&2
    exit 2
fi
for required_library in libcv_bridge libopencv_core libopencv_imgproc libopencv_highgui; do
    if ! grep "${required_library}" <<<"${viewer_linkage}" >/dev/null; then
        echo "ERROR: vision-debug-viewer is not linked to ${required_library}." >&2
        echo "${viewer_linkage}" >&2
        exit 2
    fi
done
echo "Decoupled X11 vision viewer: OK"

agent_library=/usr/local/lib/libmicroxrcedds_agent.so
if [[ ! -r "${agent_library}" ]]; then
    echo "ERROR: Agent shared library is absent: ${agent_library}" >&2
    exit 2
fi
if ! ldd "${agent_library}" | grep -Eq '/opt/ros/humble/lib/lib(fastrtps|fastcdr)'; then
    echo "ERROR: Micro XRCE-DDS Agent is not linked to the ROS Humble DDS stack." >&2
    ldd "${agent_library}" >&2
    exit 2
fi

python3 - <<'PY'
import cv2
import numpy
import scipy
import tensorrt
import torch
import torchvision
import ultralytics
from cv_bridge import CvBridge

print(f"torch={torch.__version__}")
print(f"torchvision={torchvision.__version__}")
print(f"tensorrt={tensorrt.__version__}")
print(f"ultralytics={ultralytics.__version__}")
print(f"opencv={cv2.__version__}")
print(f"numpy={numpy.__version__}")
print(f"scipy={scipy.__version__}")
print(f"cv_bridge={CvBridge.__module__}")

if not torch.cuda.is_available():
    raise SystemExit("ERROR: PyTorch cannot see Jetson CUDA through NVIDIA Container Runtime")
print(f"cuda_device={torch.cuda.get_device_name(0)}")
PY

echo "RMW=${RMW_IMPLEMENTATION}; ROS_DOMAIN_ID=${ROS_DOMAIN_ID}"
echo "Agent/Fast DDS linkage: OK"
echo "mavlink-routerd: $(command -v mavlink-routerd)"

if [[ ! -f /workspace/install/local_setup.bash ]]; then
    echo "ERROR: install volume is empty; run ./scripts/build-workspace.sh." >&2
    exit 2
fi
for package in px4_msgs detect control; do
    ros2 pkg prefix "${package}" >/dev/null
    echo "ROS package installed: ${package}"
done

if [[ ! -L /home/pixel/flylogs || "$(readlink -f /home/pixel/flylogs)" != "/workspace/log/control/csv" ]]; then
    echo "ERROR: /home/pixel/flylogs is not persisted under /workspace/log/control/csv." >&2
    exit 2
fi
echo "Control CSV compatibility path: OK"

if [[ ! -r /workspace/src/px4_msgs/package.xml ]]; then
    echo "ERROR: px4_msgs source is absent from /workspace/src." >&2
    exit 2
fi
actual_px4_msgs_version="$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' /workspace/src/px4_msgs/package.xml | head -n 1)"
if [[ "${actual_px4_msgs_version}" != "${PX4_MSGS_EXPECTED_VERSION:-}" ]]; then
    echo "ERROR: px4_msgs version is '${actual_px4_msgs_version:-unknown}', expected '${PX4_MSGS_EXPECTED_VERSION:-unset}'." >&2
    exit 2
fi
if [[ ! -e /workspace/src/px4_msgs/.git ]]; then
    echo "ERROR: px4_msgs is not an independent Git checkout or submodule." >&2
    exit 2
fi
actual_px4_msgs_commit="$(git -c safe.directory=/workspace/src/px4_msgs -C /workspace/src/px4_msgs rev-parse HEAD 2>/dev/null || true)"
if [[ -z "${PX4_MSGS_EXPECTED_COMMIT:-}" || "${actual_px4_msgs_commit}" != "${PX4_MSGS_EXPECTED_COMMIT}" ]]; then
    echo "ERROR: px4_msgs commit is '${actual_px4_msgs_commit:-unknown}', expected '${PX4_MSGS_EXPECTED_COMMIT:-unset}'." >&2
    exit 2
fi
if ! px4_msgs_status="$(git --no-optional-locks -c safe.directory=/workspace/src/px4_msgs -C /workspace/src/px4_msgs status --porcelain --untracked-files=all)"; then
    echo "ERROR: cannot inspect the px4_msgs Git checkout." >&2
    exit 2
fi
if [[ -n "${px4_msgs_status}" ]]; then
    echo "ERROR: px4_msgs has local changes or untracked files." >&2
    exit 2
fi
build_marker=/workspace/install/.26fly-px4-msgs-commit
built_px4_msgs_commit=
if [[ -r "${build_marker}" ]]; then
    built_px4_msgs_commit="$(tr -d '[:space:]' < "${build_marker}")"
fi
if [[ "${built_px4_msgs_commit}" != "${actual_px4_msgs_commit}" ]]; then
    echo "ERROR: install volume was built from px4_msgs '${built_px4_msgs_commit:-unknown}', but source is '${actual_px4_msgs_commit}'." >&2
    echo "Run ./scripts/build-workspace.sh before deployment verification." >&2
    exit 2
fi
echo "px4_msgs version=${actual_px4_msgs_version} commit=${actual_px4_msgs_commit}"

if [[ ! -d /dev/bus/usb ]]; then
    echo "ERROR: /dev/bus/usb is absent; RealSense cannot be used." >&2
    exit 2
fi
camera_listing="$(v4l2-ctl --list-devices 2>/dev/null || true)"
if ! awk -v hint="${REALSENSE_CAMERA_HINT:-RealSense}" '
    /^[^[:space:]]/ { matched = index($0, hint) > 0; next }
    matched {
        device = $0
        sub(/^[[:space:]]+/, "", device)
        if (device ~ /^\/dev\/video[0-9]+$/) found = 1
    }
    END { exit(found ? 0 : 1) }
' <<< "${camera_listing}"; then
    echo "ERROR: no RealSense video group matched hint '${REALSENSE_CAMERA_HINT:-RealSense}'." >&2
    exit 2
fi
echo "RealSense USB/video enumeration: OK"

wide_camera_device="${WIDE_CAMERA_DEVICE:-}"
wide_camera_hint="${CONTROL_CAMERA_HINT:-}"
if [[ ! -c "${wide_camera_device}" ]]; then
    echo "ERROR: wide-camera character device is absent: ${wide_camera_device:-<unset>}" >&2
    exit 2
fi
wide_camera_real="$(readlink -f -- "${wide_camera_device}" 2>/dev/null || true)"
if [[ -z "${wide_camera_real}" || ! -c "${wide_camera_real}" ]]; then
    echo "ERROR: wide-camera path does not resolve to a character device: ${wide_camera_device}" >&2
    exit 2
fi
if ! awk -v hint="${wide_camera_hint}" -v wanted="${wide_camera_real}" '
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
    echo "ERROR: camera hint '${wide_camera_hint}' does not select ${wide_camera_device} -> ${wide_camera_real} as its first video node." >&2
    exit 2
fi
if ! v4l2-ctl --device "${wide_camera_device}" --list-formats-ext >/dev/null 2>&1; then
    echo "ERROR: ${wide_camera_device} does not expose usable V4L2 capture formats." >&2
    exit 2
fi
echo "Wide camera=${wide_camera_device} -> ${wide_camera_real} hint=${wide_camera_hint}"

declare -A verified_models=()
for label_and_model in \
    "Detector:${DETECT_MODEL:-}" \
    "Control:${CONTROL_MODEL:-}"; do
    label="${label_and_model%%:*}"
    model="${label_and_model#*:}"
    if [[ -z "${model}" || ! -r "${model}" ]]; then
        echo "ERROR: ${label} model is not readable: ${model:-<unset>}" >&2
        exit 2
    fi
    if [[ "${model}" != *.engine ]]; then
        echo "ERROR: ${label} model is not a TensorRT .engine file: ${model}" >&2
        exit 2
    fi
    if [[ -n "${verified_models[${model}]+present}" ]]; then
        echo "${label} model reuses verified engine: ${model}"
        continue
    fi
    VERIFY_MODEL_PATH="${model}" python3 - <<'PY'
import os
import numpy as np
from ultralytics import YOLO

path = os.environ["VERIFY_MODEL_PATH"]
model = YOLO(path)
frame = np.zeros((480, 640, 3), dtype=np.uint8)
results = model.predict(source=frame, verbose=False)
if len(results) != 1 or not hasattr(results[0], "boxes"):
    raise RuntimeError("TensorRT smoke inference did not return one detection result")
print(f"model_inference=ok path={path} task={model.task}")
PY
    verified_models["${model}"]=1
done

#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

pid1="$(ps -p 1 -o comm= | tr -d '[:space:]')"
if [[ "${pid1}" != "systemd" ]]; then
    echo "ERROR: expected container PID 1 to be systemd, got '${pid1}'." >&2
    exit 2
fi
systemctl is-active --quiet 26fly.target
for service in micro-xrce-agent.service mavlink-routerd.service; do
    if [[ "$(systemctl is-enabled "${service}")" != "enabled" ]]; then
        echo "ERROR: ${service} is not enabled in 26fly.target." >&2
        exit 2
    fi
    if [[ "$(systemctl show --property=Restart --value "${service}")" != "always" ]]; then
        echo "ERROR: ${service} does not use Restart=always." >&2
        exit 2
    fi
done

[[ "${RMW_IMPLEMENTATION}" == "rmw_fastrtps_cpp" ]]
command -v MicroXRCEAgent >/dev/null
command -v mavlink-routerd >/dev/null

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

if [[ -f /workspace/install/local_setup.bash ]]; then
    for package in px4_msgs detect control; do
        ros2 pkg prefix "${package}" >/dev/null
        echo "ROS package installed: ${package}"
    done
else
    echo "INFO: install volume is empty; run ./scripts/build-workspace.sh."
fi

model="${VERIFY_MODEL_PATH:-${DETECT_MODEL:-}}"
if [[ -n "${model}" && -r "${model}" ]]; then
    VERIFY_MODEL_PATH="${model}" python3 - <<'PY'
import os
from ultralytics import YOLO

path = os.environ["VERIFY_MODEL_PATH"]
model = YOLO(path)
print(f"model_load=ok path={path} task={model.task}")
PY
else
    echo "INFO: no readable model selected; skipped YOLO model-load test."
fi

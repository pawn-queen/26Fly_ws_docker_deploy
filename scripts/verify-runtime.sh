#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1090
source "/opt/ros/${ROS_DISTRO:-humble}/setup.bash"
if [[ -f /workspace/install/local_setup.bash ]]; then
    # shellcheck disable=SC1091
    source /workspace/install/local_setup.bash
fi

python3 - <<'PY'
import cv2
import numpy
import scipy
import torch
import ultralytics
from cv_bridge import CvBridge

print(f"torch={torch.__version__}")
print(f"torchvision_cuda_available={torch.cuda.is_available()}")
print(f"ultralytics={ultralytics.__version__}")
print(f"opencv={cv2.__version__}")
print(f"numpy={numpy.__version__}")
print(f"scipy={scipy.__version__}")
print(f"cv_bridge={CvBridge.__module__}")

if not torch.cuda.is_available():
    raise SystemExit("ERROR: torch cannot see Jetson CUDA through NVIDIA Container Runtime")

print(f"cuda_device={torch.cuda.get_device_name(0)}")
PY

echo
echo "ROS packages visible below /workspace/src:"
colcon list --base-paths /workspace/src

if [[ -f /workspace/install/local_setup.bash ]]; then
    for package in px4_msgs detect control; do
        ros2 pkg prefix "${package}" >/dev/null
        echo "ROS package installed: ${package}"
    done
else
    echo "INFO: install volume is empty; run build-workspace before checking the overlay."
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

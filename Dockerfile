# syntax=docker/dockerfile:1.7

# Jetson 专用镜像，包含与 JetPack 6 配套的 PyTorch/TensorRT/Ultralytics。
# 不要替换为普通 ubuntu、通用 CUDA 或 PyPI torch 镜像。
ARG BASE_IMAGE=ultralytics/ultralytics:8.4.138-jetson-jetpack6
FROM ${BASE_IMAGE}

ARG ROS_DISTRO=humble
ARG USER_NAME=jetson
ARG USER_UID=1000
ARG USER_GID=1000
ARG ULTRALYTICS_VERSION=8.4.138

LABEL org.opencontainers.image.title="26Fly Jetson ROS 2 runtime" \
      org.opencontainers.image.description="ROS 2 Humble and vision runtime for Jetson Orin Nano Super" \
      io.26fly.ros-distro="${ROS_DISTRO}" \
      io.26fly.ultralytics-version="${ULTRALYTICS_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    ROS_DISTRO=${ROS_DISTRO} \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    YOLO_AUTOINSTALL=false

# 这里只安装用户态工具。Jetson BSP、内核模块和 NVIDIA 驱动必须留在宿主机。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        locales \
    && locale-gen en_US en_US.UTF-8 \
    && curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME}") main" \
        > /etc/apt/sources.list.d/ros2.list \
    && rm -rf /var/lib/apt/lists/*

COPY apt-packages.txt /tmp/26fly-apt-packages.txt

RUN apt-get update \
    && mapfile -t packages < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' /tmp/26fly-apt-packages.txt) \
    && apt-get install -y --no-install-recommends "${packages[@]}" \
    && if [[ ! -e /etc/ros/rosdep/sources.list.d/20-default.list ]]; then rosdep init; fi \
    && rm -rf /var/lib/apt/lists/* /tmp/26fly-apt-packages.txt

# torch、torchvision 和 Ultralytics 由 Jetson 基础镜像提供，绝不能让普通
# PyPI wheel 覆盖。NumPy/OpenCV/SciPy/lap 则按 ROS Humble ABI 显式锁定。
COPY requirements.txt /tmp/26fly-requirements.txt
RUN python3 -m pip install --no-cache-dir --no-deps -r /tmp/26fly-requirements.txt \
    && python3 -m pip check \
    && python3 -c "from importlib.metadata import version; expected='${ULTRALYTICS_VERSION}'; actual=version('ultralytics'); assert actual == expected, f'expected ultralytics {expected}, got {actual}'; print('ultralytics', actual)" \
    && source "/opt/ros/${ROS_DISTRO}/setup.bash" \
    && python3 -c "import cv2, lap, numpy, scipy, torch, ultralytics; from cv_bridge import CvBridge; a=numpy.zeros((2,2,3), dtype=numpy.uint8); b=CvBridge(); m=b.cv2_to_imgmsg(a, encoding='bgr8'); out=b.imgmsg_to_cv2(m, desired_encoding='bgr8'); assert numpy.array_equal(a, out); assert numpy.__version__ == '1.24.3'; assert cv2.__version__ == '4.11.0'; print('joint Python/cv_bridge import and conversion: OK')" \
    && rm -f /tmp/26fly-requirements.txt

# 保留名字可读的非 root 用户。Compose 仍会显式传入宿主 UID/GID。
RUN if ! getent group "${USER_GID}" >/dev/null; then groupadd --gid "${USER_GID}" "${USER_NAME}"; fi \
    && if ! getent passwd "${USER_UID}" >/dev/null; then \
         useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USER_NAME}"; \
       fi \
    && mkdir -p \
         /workspace/src \
         /workspace/build \
         /workspace/install \
         /workspace/log/control/csv \
         /workspace/log/control/photos \
         /workspace/log/control/videos \
         /workspace/log/detect/videos \
         /workspace/log/home \
         /workspace/models \
         /home/kpc \
    && ln -s /workspace/log/control/csv /home/kpc/flylogs \
    && ln -s /workspace/log/detect/videos /home/depth_videos \
    && ln -s /workspace/log/control/photos /home/image_recodes \
    && ln -s /workspace/log/control/videos /home/video_recodes \
    && ln -s /workspace/models /home/weights \
    && chown -R "${USER_UID}:${USER_GID}" /workspace /home/kpc

COPY --chmod=0755 scripts/container-entrypoint.sh /usr/local/bin/26fly-entrypoint
COPY --chmod=0755 scripts/build-workspace.sh /usr/local/bin/build-workspace
COPY --chmod=0755 scripts/run-detect.sh /usr/local/bin/run-detect
COPY --chmod=0755 scripts/run-control.sh /usr/local/bin/run-control
COPY --chmod=0755 scripts/run-camera.sh /usr/local/bin/run-camera
COPY --chmod=0755 scripts/verify-runtime.sh /usr/local/bin/verify-runtime
COPY --chmod=0755 scripts/check-rosdep.sh /usr/local/bin/check-rosdep

ENV HOME=/workspace/log/home \
    ROS_HOME=/workspace/log/home/.ros \
    ROS_LOG_DIR=/workspace/log/ros \
    XDG_CACHE_HOME=/workspace/log/cache \
    TORCH_HOME=/workspace/log/cache/torch \
    YOLO_CONFIG_DIR=/workspace/log/config/ultralytics \
    MPLCONFIGDIR=/workspace/log/config/matplotlib

WORKDIR /workspace
USER ${USER_UID}:${USER_GID}

ENTRYPOINT ["/usr/local/bin/26fly-entrypoint"]
CMD ["bash"]

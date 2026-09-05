# syntax=docker/dockerfile:1.7

# Jetson 专用基础镜像。CUDA/TensorRT/PyTorch 来自与 JetPack 6 配套的镜像，
# Jetson BSP、内核模块和 NVIDIA 驱动始终属于宿主机，不在容器中安装。
ARG BASE_IMAGE=ultralytics/ultralytics:8.4.138-jetson-jetpack6
FROM ${BASE_IMAGE}

USER root

ARG ROS_DISTRO=humble
ARG ULTRALYTICS_VERSION=8.4.138
ARG XRCE_AGENT_VERSION=v2.4.2
ARG MAVLINK_ROUTER_VERSION=v4
ARG BUILD_JOBS=2

LABEL org.opencontainers.image.title="26Fly Jetson pet runtime" \
      org.opencontainers.image.description="Single long-lived Jetson runtime: ROS 2, vision, XRCE Agent and mavlink-router" \
      io.26fly.ros-distro="${ROS_DISTRO}" \
      io.26fly.rmw="rmw_fastrtps_cpp" \
      io.26fly.xrce-agent="${XRCE_AGENT_VERSION}" \
      io.26fly.mavlink-router="${MAVLINK_ROUTER_VERSION}" \
      io.26fly.ultralytics-version="${ULTRALYTICS_VERSION}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker \
    ROS_DISTRO=${ROS_DISTRO} \
    RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    ROS_LOCALHOST_ONLY=0 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    YOLO_AUTOINSTALL=false

RUN test "${ROS_DISTRO}" = humble

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

# Agent 与 ROS 2 使用同一套 Humble Fast DDS/Fast CDR 动态库。这里明确启用
# UAGENT_USE_SYSTEM_*，不要改回 Agent superbuild 自带的 Fast DDS。
RUN git clone --branch "${XRCE_AGENT_VERSION}" --depth 1 \
        https://github.com/eProsima/Micro-XRCE-DDS-Agent.git /tmp/Micro-XRCE-DDS-Agent \
    && source "/opt/ros/${ROS_DISTRO}/setup.bash" \
    && cmake -S /tmp/Micro-XRCE-DDS-Agent -B /tmp/Micro-XRCE-DDS-Agent/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/opt/ros/humble \
        -DUAGENT_SUPERBUILD=OFF \
        -DUAGENT_USE_SYSTEM_FASTDDS=ON \
        -DUAGENT_USE_SYSTEM_FASTCDR=ON \
        -DUAGENT_USE_SYSTEM_LOGGER=ON \
        -DUAGENT_CED_PROFILE=OFF \
        -DUAGENT_P2P_PROFILE=OFF \
        -DUAGENT_SOCKETCAN_PROFILE=OFF \
        -DUAGENT_BUILD_TESTS=OFF \
        -DUAGENT_BUILD_USAGE_EXAMPLES=OFF \
    && cmake --build /tmp/Micro-XRCE-DDS-Agent/build --parallel "${BUILD_JOBS}" \
    && cmake --install /tmp/Micro-XRCE-DDS-Agent/build \
    && rm -rf /tmp/Micro-XRCE-DDS-Agent \
    && ldconfig

RUN git clone --branch "${MAVLINK_ROUTER_VERSION}" --depth 1 \
        --recurse-submodules --shallow-submodules \
        https://github.com/mavlink-router/mavlink-router.git /tmp/mavlink-router \
    && meson setup /tmp/mavlink-router/build /tmp/mavlink-router \
        --buildtype=release \
        --prefix=/usr/local \
        -Dsystemdsystemunitdir=/tmp/26fly-unused-systemd \
    && meson compile -C /tmp/mavlink-router/build -j "${BUILD_JOBS}" \
    && meson install -C /tmp/mavlink-router/build \
    && rm -rf /tmp/mavlink-router /tmp/26fly-unused-systemd

# torch、torchvision、TensorRT 和 Ultralytics 均由 Jetson 基础镜像提供；
# 禁止普通 PyPI torch wheel 覆盖 Jetson 构建。
COPY requirements.txt /tmp/26fly-requirements.txt
RUN python3 -m pip install --no-cache-dir --no-deps -r /tmp/26fly-requirements.txt \
    && python3 -m pip check \
    && python3 -c "from importlib.metadata import version; expected='${ULTRALYTICS_VERSION}'; actual=version('ultralytics'); assert actual == expected, f'expected ultralytics {expected}, got {actual}'" \
    && source "/opt/ros/${ROS_DISTRO}/setup.bash" \
    && python3 -c "import cv2, numpy, scipy, tensorrt, torch, torchvision, ultralytics; from cv_bridge import CvBridge; a=numpy.zeros((2,2,3), dtype=numpy.uint8); b=CvBridge(); assert numpy.array_equal(a, b.imgmsg_to_cv2(b.cv2_to_imgmsg(a, encoding='bgr8'), desired_encoding='bgr8')); assert numpy.__version__ == '1.24.3'; assert cv2.__version__ == '4.11.0'" \
    && rm -f /tmp/26fly-requirements.txt

# 按初步方案固定为 root 运行。源码在 docker create 时只读挂载；root 的输出
# 只进入 build/install/log named volume。
RUN mkdir -p \
        /etc/26fly \
        /workspace/src \
        /workspace/build \
        /workspace/install \
        /workspace/log/ros \
        /workspace/log/control/csv \
        /workspace/log/control/photos \
        /workspace/log/control/videos \
        /workspace/log/detect/videos \
        /workspace/models \
        /home/kpc \
    && ln -s /workspace/log/control/csv /home/kpc/flylogs \
    && ln -s /workspace/log/detect/videos /home/depth_videos \
    && ln -s /workspace/log/control/photos /home/image_recodes \
    && ln -s /workspace/log/control/videos /home/video_recodes \
    && ln -s /workspace/models /home/weights

COPY --chmod=0755 container/build-workspace.sh /usr/local/bin/build-workspace
COPY --chmod=0755 container/check-rosdep.sh /usr/local/bin/check-rosdep
COPY --chmod=0755 container/env.sh /usr/local/lib/26fly/env.sh
COPY --chmod=0755 container/resolve-device.sh /usr/local/bin/resolve-device
COPY --chmod=0755 container/run-camera.sh /usr/local/bin/run-camera
COPY --chmod=0755 container/run-control.sh /usr/local/bin/run-control
COPY --chmod=0755 container/run-detect.sh /usr/local/bin/run-detect
COPY --chmod=0755 container/run-mavlink-routerd.sh /usr/local/bin/run-mavlink-routerd
COPY --chmod=0755 container/run-micro-xrce-agent.sh /usr/local/bin/run-micro-xrce-agent
COPY --chmod=0755 container/shell.sh /usr/local/bin/26fly-shell
COPY --chmod=0755 container/verify-runtime.sh /usr/local/bin/verify-runtime
COPY container/systemd/26fly.target /etc/systemd/system/26fly.target
COPY container/systemd/micro-xrce-agent.service /etc/systemd/system/micro-xrce-agent.service
COPY container/systemd/mavlink-routerd.service /etc/systemd/system/mavlink-routerd.service

# 只启用两个通信服务。自定义 target 不拉起普通主机式 multi-user 服务；同时
# 显式屏蔽会与宿主 /dev、内核参数或内核模块争用的单元。
RUN SYSTEMD_OFFLINE=1 systemctl enable micro-xrce-agent.service mavlink-routerd.service \
    && SYSTEMD_OFFLINE=1 systemctl mask \
        systemd-udevd.service \
        systemd-udevd-control.socket \
        systemd-udevd-kernel.socket \
        systemd-udev-trigger.service \
        systemd-tmpfiles-setup-dev.service \
        systemd-modules-load.service \
        systemd-sysctl.service \
    && truncate -s 0 /etc/machine-id

ENV ROS_HOME=/workspace/log/ros-home \
    ROS_LOG_DIR=/workspace/log/ros \
    XDG_CACHE_HOME=/workspace/log/cache \
    TORCH_HOME=/workspace/log/cache/torch \
    YOLO_CONFIG_DIR=/workspace/log/config/ultralytics \
    MPLCONFIGDIR=/workspace/log/config/matplotlib

WORKDIR /workspace
USER root

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
CMD ["--unit=26fly.target"]

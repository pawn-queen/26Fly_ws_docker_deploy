#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command docker

if container_exists; then
    echo "REFUSED: '${CONTAINER_NAME}' already exists; this is a persistent pet container." >&2
    echo "Use start/stop/exec for daily work. Recreate it only as an explicit migration." >&2
    exit 3
fi

for required_dir in "${HOST_WS_SRC}" "${HOST_MODEL_DIR}" "${HOST_CONFIG_DIR}"; do
    if [[ ! -d "${required_dir}" ]]; then
        echo "ERROR: required host directory is absent: ${required_dir}" >&2
        exit 2
    fi
done
if [[ ! -r "${HOST_CONFIG_DIR}/runtime.env" ]]; then
    echo "ERROR: missing runtime configuration: ${HOST_CONFIG_DIR}/runtime.env" >&2
    exit 2
fi
if ! docker image inspect "${APP_IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: image '${APP_IMAGE}' is absent. Run ./scripts/build-image.sh first." >&2
    exit 2
fi

build_volume="${VOLUME_PREFIX}-build"
install_volume="${VOLUME_PREFIX}-install"
log_volume="${VOLUME_PREFIX}-log"
for volume in "${build_volume}" "${install_volume}" "${log_volume}"; do
    docker volume create "${volume}" >/dev/null
done

optional_mounts=()
if [[ -d /run/udev ]]; then
    optional_mounts+=(--volume /run/udev:/run/udev:ro)
fi
if [[ -S /tmp/argus_socket ]]; then
    optional_mounts+=(--volume /tmp/argus_socket:/tmp/argus_socket)
fi
if [[ -d /tmp/.X11-unix ]]; then
    optional_mounts+=(--volume /tmp/.X11-unix:/tmp/.X11-unix:ro)
else
    echo "WARNING: /tmp/.X11-unix is absent; this container will not support the optional GUI debug entry." >&2
fi

docker create \
    --name "${CONTAINER_NAME}" \
    --hostname "${CONTAINER_NAME}" \
    --platform linux/arm64 \
    --runtime nvidia \
    --network host \
    --ipc host \
    --cgroupns private \
    --privileged \
    --restart unless-stopped \
    --stop-signal SIGRTMIN+3 \
    --stop-timeout 30 \
    --tmpfs /run:rw,nosuid,nodev,mode=755 \
    --tmpfs /run/lock:rw,nosuid,nodev,noexec,mode=1777 \
    --volume /dev:/dev \
    "${optional_mounts[@]}" \
    --mount "type=bind,src=${HOST_WS_SRC},dst=/workspace/src,readonly" \
    --mount "type=bind,src=${HOST_MODEL_DIR},dst=/workspace/models,readonly" \
    --mount "type=bind,src=${HOST_CONFIG_DIR},dst=/etc/26fly,readonly" \
    --mount "type=volume,src=${build_volume},dst=/workspace/build" \
    --mount "type=volume,src=${install_volume},dst=/workspace/install" \
    --mount "type=volume,src=${log_volume},dst=/workspace/log" \
    --env ROS_DISTRO=humble \
    --env RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    --env ROS_LOCALHOST_ONLY=0 \
    --env NVIDIA_VISIBLE_DEVICES=all \
    --env NVIDIA_DRIVER_CAPABILITIES=all \
    "${APP_IMAGE}" >/dev/null

echo "Created persistent container: ${CONTAINER_NAME}"
echo "src:     ${HOST_WS_SRC} -> /workspace/src (read-only)"
echo "config:  ${HOST_CONFIG_DIR} -> /etc/26fly (read-only)"
echo "volumes: ${build_volume}, ${install_volume}, ${log_volume}"
if [[ -d /tmp/.X11-unix ]]; then
    echo "debug X11: /tmp/.X11-unix -> /tmp/.X11-unix (read-only; DISPLAY is per invocation)"
fi
echo "security mode: root + privileged + /dev:/dev (required by 初步方案.md)"
echo "PID 1: /sbin/init (container-internal systemd, cgroup namespace: private)"
echo "Next: ./scripts/start-runtime.sh"

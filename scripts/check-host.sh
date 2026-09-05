#!/usr/bin/env bash
set -uo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings || exit $?

failures=0
warnings=0
ok() { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

runtime_value() {
    local key=$1
    local value
    value="$(awk -v key="${key}" '
        index($0, key "=") == 1 { value=substr($0, length(key) + 2) }
        END { print value }
    ' "${HOST_CONFIG_DIR}/runtime.env" 2>/dev/null)"
    value="${value%$'\r'}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "${value}"
}

if [[ "$(uname -m)" == "aarch64" ]]; then
    ok "architecture is aarch64"
else
    fail "architecture is $(uname -m); the runtime image is Jetson aarch64-only"
fi

if [[ -r /etc/nv_tegra_release ]]; then
    ok "Jetson BSP marker: $(head -n 1 /etc/nv_tegra_release)"
elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W nvidia-l4t-core >/dev/null 2>&1; then
    ok "nvidia-l4t-core is installed"
else
    fail "Jetson Linux BSP was not detected"
fi

if command -v docker >/dev/null 2>&1; then
    ok "docker command is installed"
    runtimes="$(docker info --format '{{json .Runtimes}}' 2>/dev/null || true)"
    if grep -q nvidia <<< "${runtimes}"; then
        ok "NVIDIA container runtime is registered"
    else
        fail "NVIDIA runtime is not visible in docker info"
    fi
    cgroup_version="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)"
    if [[ "${cgroup_version}" == "2" ]]; then
        ok "Docker uses cgroup v2"
    else
        fail "Docker cgroup version is '${cgroup_version:-unknown}'; container PID-1 systemd requires the JetPack 6 cgroup-v2 setup"
    fi
else
    fail "docker is not installed"
fi

for package_file in \
    "${HOST_WS_SRC}/detect/package.xml" \
    "${HOST_WS_SRC}/fly/package.xml" \
    "${HOST_WS_SRC}/px4_msgs/package.xml"; do
    if [[ -r "${package_file}" ]]; then
        ok "source found: ${package_file}"
    else
        fail "missing source: ${package_file}"
    fi
done

if [[ -r "${HOST_CONFIG_DIR}/runtime.env" ]]; then
    ok "runtime config is readable: ${HOST_CONFIG_DIR}/runtime.env"
    xrce_transport="$(runtime_value XRCE_TRANSPORT)"
    mavlink_transport="$(runtime_value MAVLINK_TRANSPORT)"
    xrce_device="$(runtime_value XRCE_SERIAL_DEVICE)"
    mavlink_device="$(runtime_value MAVLINK_SERIAL_DEVICE)"
    if [[ "${xrce_transport}" == "serial" && "${mavlink_transport}" == "serial" ]]; then
        xrce_real="$(readlink -f -- "${xrce_device}" 2>/dev/null || printf '%s' "${xrce_device}")"
        mavlink_real="$(readlink -f -- "${mavlink_device}" 2>/dev/null || printf '%s' "${mavlink_device}")"
        if [[ "${xrce_real}" == "${mavlink_real}" ]]; then
            fail "XRCE and MAVLink are configured to use the same serial device: ${xrce_device}"
        else
            ok "XRCE and MAVLink serial inputs are distinct in configuration"
        fi
        for label_and_device in "XRCE:${xrce_device}" "MAVLink:${mavlink_device}"; do
            label="${label_and_device%%:*}"
            device="${label_and_device#*:}"
            if [[ -c "${device}" ]]; then
                ok "${label} serial device exists: ${device}"
            else
                warn "${label} serial device is currently absent: ${device}"
            fi
        done
    fi
else
    fail "runtime config is missing: ${HOST_CONFIG_DIR}/runtime.env"
fi

if [[ -d /dev/bus/usb ]]; then
    ok "/dev/bus/usb exists"
else
    warn "/dev/bus/usb is absent; RealSense will not be available"
fi

if command -v docker >/dev/null 2>&1 && container_exists; then
    privileged="$(docker inspect --format '{{.HostConfig.Privileged}}' "${CONTAINER_NAME}")"
    runtime="$(docker inspect --format '{{.HostConfig.Runtime}}' "${CONTAINER_NAME}")"
    cgroup_namespace="$(docker inspect --format '{{.HostConfig.CgroupnsMode}}' "${CONTAINER_NAME}")"
    entrypoint="$(docker inspect --format '{{json .Config.Entrypoint}}' "${CONTAINER_NAME}")"
    command="$(docker inspect --format '{{json .Config.Cmd}}' "${CONTAINER_NAME}")"
    pid_mode="$(docker inspect --format '{{.HostConfig.PidMode}}' "${CONTAINER_NAME}")"
    user="$(docker inspect --format '{{.Config.User}}' "${CONTAINER_NAME}")"
    mounts="$(docker inspect --format '{{range .Mounts}}{{println .Destination .RW .Type .Source}}{{end}}' "${CONTAINER_NAME}")"

    if [[ "${privileged}" == "true" ]]; then ok "runtime is privileged"; else fail "runtime is not privileged"; fi
    if [[ "${runtime}" == "nvidia" ]]; then ok "runtime uses NVIDIA container runtime"; else fail "container runtime is '${runtime}'"; fi
    if [[ "${cgroup_namespace}" == "private" ]]; then ok "runtime uses a private cgroup namespace"; else fail "cgroup namespace is '${cgroup_namespace}'"; fi
    if [[ "${entrypoint}" == '["/sbin/init"]' ]]; then ok "container entrypoint is /sbin/init"; else fail "container entrypoint is ${entrypoint}"; fi
    if [[ "${command}" == '["--unit=26fly.target"]' ]]; then ok "systemd boots 26fly.target"; else fail "container command is ${command}"; fi
    if [[ -z "${pid_mode}" ]]; then ok "runtime has a private PID namespace"; else fail "PID namespace mode is '${pid_mode}'"; fi
    if [[ -z "${user}" || "${user}" == "root" || "${user}" == "0" ]]; then ok "runtime user is root"; else fail "runtime user is '${user}'"; fi
    if grep -Eq '^/dev true bind /dev$' <<< "${mounts}"; then ok "/dev:/dev bind mount is present"; else fail "/dev:/dev bind mount is absent"; fi
    if grep -Eq '^/workspace/src false bind ' <<< "${mounts}"; then ok "/workspace/src bind mount is read-only"; else fail "/workspace/src is not a read-only bind mount"; fi
    volume_count="$(grep -Ec '^/workspace/(build|install|log) true volume ' <<< "${mounts}" || true)"
    if [[ "${volume_count}" == "3" ]]; then ok "all three workspace named volumes are present"; else fail "workspace named volumes are incomplete"; fi
    if container_running; then
        pid1="$(docker exec "${CONTAINER_NAME}" ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${pid1}" == "systemd" ]]; then ok "container PID 1 is systemd"; else fail "container PID 1 is '${pid1:-unknown}'"; fi
    fi
else
    warn "persistent container '${CONTAINER_NAME}' has not been created yet"
fi

printf '\nHost check: %d failure(s), %d warning(s).\n' "${failures}" "${warnings}"
(( failures == 0 ))

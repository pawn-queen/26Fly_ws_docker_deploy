#!/usr/bin/env bash
set -uo pipefail

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
failures=0
warnings=0

ok() { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

arch="$(uname -m)"
if [[ "${arch}" == "aarch64" ]]; then
    ok "architecture is aarch64"
else
    fail "architecture is ${arch}; this image is intended for the Jetson aarch64 host"
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
    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose plugin is available"
    else
        fail "docker compose plugin is unavailable"
    fi
    runtimes="$(docker info --format '{{json .Runtimes}}' 2>/dev/null || true)"
    if grep -q 'nvidia' <<< "${runtimes}"; then
        ok "NVIDIA container runtime is registered"
    else
        fail "NVIDIA container runtime is not visible in docker info"
    fi
else
    fail "docker is not installed"
fi

dotenv_value() {
    local key=$1
    local value
    value="$(sed -n "s/^${key}=//p" "${deploy_dir}/.env" | tail -n 1)"
    value="${value%$'\r'}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s\n' "${value}"
}

source_dir="${HOST_WS_SRC:-/home/queen/uav/26Season_Fly_ws_archive/src}"
wide_camera_device="${WIDE_CAMERA_DEVICE:-/dev/video0}"
px4_serial_device="${PX4_SERIAL_DEVICE:-/dev/ttyACM1}"
if [[ -f "${deploy_dir}/.env" ]]; then
    # Compose dotenv syntax is not Bash syntax. Read only the keys needed here; never eval/source it.
    source_dir="$(dotenv_value HOST_WS_SRC)"
    wide_camera_device="$(dotenv_value WIDE_CAMERA_DEVICE)"
    px4_serial_device="$(dotenv_value PX4_SERIAL_DEVICE)"
fi

for package_file in \
    "${source_dir}/detect/package.xml" \
    "${source_dir}/fly/package.xml" \
    "${source_dir}/px4_msgs/package.xml"; do
    if [[ -r "${package_file}" ]]; then
        ok "source found: ${package_file}"
    else
        fail "missing source: ${package_file}"
    fi
done

if [[ -d /dev/bus/usb ]]; then
    ok "/dev/bus/usb exists (RealSense can be mapped)"
else
    warn "/dev/bus/usb is absent"
fi

if [[ -e "${wide_camera_device}" ]]; then
    ok "wide camera candidate exists: ${wide_camera_device}"
else
    warn "wide camera candidate is absent: ${wide_camera_device}"
fi

if [[ -e "${px4_serial_device}" ]]; then
    ok "PX4 serial candidate exists: ${px4_serial_device}"
else
    warn "PX4 serial candidate is absent: ${px4_serial_device}"
fi

printf '\nHost check: %d failure(s), %d warning(s).\n' "${failures}" "${warnings}"
if (( failures > 0 )); then
    exit 1
fi

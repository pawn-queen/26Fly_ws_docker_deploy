#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command xauth
require_command setsid

if [[ -z "${DISPLAY:-}" ]]; then
    echo "ERROR: DISPLAY is empty. Run this script from the Jetson GUI/remote-desktop terminal." >&2
    exit 2
fi

display_number=
if [[ "${DISPLAY}" =~ ^:([0-9]+)(\.[0-9]+)?$ ]]; then
    display_number="${BASH_REMATCH[1]}"
elif [[ "${DISPLAY}" =~ ^unix:([0-9]+)(\.[0-9]+)?$ ]]; then
    display_number="${BASH_REMATCH[1]}"
else
    echo "ERROR: unsupported DISPLAY '${DISPLAY}'; expected a local X11 display such as :1002." >&2
    exit 2
fi

x_socket="/tmp/.X11-unix/X${display_number}"
if [[ ! -S "${x_socket}" ]]; then
    echo "ERROR: X11 socket is absent on the host: ${x_socket}" >&2
    exit 2
fi
authority_records="$(xauth nlist "${DISPLAY}" 2>/dev/null || true)"
if [[ -z "${authority_records}" ]]; then
    authority_records="$(xauth nlist ":${display_number}" 2>/dev/null || true)"
fi
if [[ -z "${authority_records}" ]]; then
    echo "ERROR: no Xauthority cookie was found for DISPLAY=${DISPLAY}." >&2
    echo "Run as the logged-in GUI user and check DISPLAY/XAUTHORITY; this script will not use xhost +." >&2
    exit 2
fi

ensure_runtime_running
if ! docker exec "${CONTAINER_NAME}" test -S "${x_socket}"; then
    echo "ERROR: ${x_socket} is not visible in ${CONTAINER_NAME}." >&2
    echo "Rebuild the image and recreate the persistent container with the X11 bind mount." >&2
    exit 2
fi
if ! docker exec "${CONTAINER_NAME}" sh -c \
    'command -v xauth >/dev/null && command -v vision-debug-viewer >/dev/null && command -v run-vision-debug >/dev/null'; then
    echo "ERROR: the running container does not contain the GUI debug tools." >&2
    echo "Run ./scripts/build-image.sh, then perform the documented preserve-and-recreate migration." >&2
    exit 2
fi

container_xauthority="$(docker exec "${CONTAINER_NAME}" \
    mktemp /run/26fly-xauthority.XXXXXX)"
session_id="${UID}-${RANDOM}${RANDOM}-$$"
debug_exec_pid=
debug_session_started=false
debug_stop_confirmed=false
signal_status=0

request_debug_stop() {
    local attempt stop_status

    if [[ "${debug_session_started}" != "true" || "${debug_stop_confirmed}" == "true" ]]; then
        return 0
    fi
    for ((attempt = 0; attempt < 50; attempt++)); do
        if docker exec "${CONTAINER_NAME}" \
            run-vision-debug --stop "${session_id}"; then
            debug_stop_confirmed=true
            return 0
        else
            stop_status=$?
        fi
        if (( stop_status != 4 )); then
            echo "ERROR: failed to stop vision debug session ${session_id} (status=${stop_status})." >&2
            return 1
        fi
        sleep 0.1
    done
    echo "ERROR: vision debug session ${session_id} did not register a stoppable container process." >&2
    return 1
}

handle_signal() {
    local status=$1
    local signal_name=$2

    if (( signal_status == 0 )); then
        signal_status=${status}
        trap '' INT TERM HUP
        echo "Received ${signal_name}; explicitly stopping container vision debug session ${session_id}." >&2
        request_debug_stop || true
    fi
    exit "${signal_status}"
}

cleanup() {
    local original_status=$?

    trap - EXIT INT TERM HUP
    if [[ "${debug_session_started}" == "true" && "${debug_stop_confirmed}" != "true" ]]; then
        request_debug_stop || true
    fi
    if [[ -n "${debug_exec_pid}" ]]; then
        wait "${debug_exec_pid}" 2>/dev/null || true
        debug_exec_pid=
    fi
    if [[ -n "${container_xauthority:-}" ]]; then
        docker exec "${CONTAINER_NAME}" rm -f -- "${container_xauthority}" \
            >/dev/null 2>&1 || true
    fi
    return "${original_status}"
}
trap cleanup EXIT
trap 'handle_signal 130 SIGINT' INT
trap 'handle_signal 143 SIGTERM' TERM
trap 'handle_signal 129 SIGHUP' HUP

if ! printf '%s\n' "${authority_records}" | sed 's/^..../ffff/' | \
    docker exec -i "${CONTAINER_NAME}" \
        xauth -f "${container_xauthority}" nmerge -; then
    echo "ERROR: failed to install the temporary Xauthority cookie in the container." >&2
    exit 2
fi
docker exec "${CONTAINER_NAME}" chmod 0600 "${container_xauthority}"

echo "Starting RealSense-only GUI debug session ${session_id}; the IMX577 wide camera is not part of this stack."
set +e
setsid --fork --wait docker exec \
    --env "DISPLAY=${DISPLAY}" \
    --env "XAUTHORITY=${container_xauthority}" \
    --env QT_X11_NO_MITSHM=1 \
    "${CONTAINER_NAME}" run-vision-debug "${session_id}" &
debug_exec_pid=$!
debug_session_started=true

while true; do
    if wait "${debug_exec_pid}"; then
        status=0
        break
    else
        status=$?
    fi
    if kill -0 "${debug_exec_pid}" 2>/dev/null; then
        continue
    fi
    break
done
debug_exec_pid=
debug_session_started=false
set -e

if (( signal_status != 0 )); then
    exit "${signal_status}"
fi
exit "${status}"

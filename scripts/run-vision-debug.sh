#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command xauth

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
cleanup() {
    if [[ -n "${container_xauthority:-}" ]]; then
        docker exec "${CONTAINER_NAME}" rm -f -- "${container_xauthority}" \
            >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if ! printf '%s\n' "${authority_records}" | sed 's/^..../ffff/' | \
    docker exec -i "${CONTAINER_NAME}" \
        xauth -f "${container_xauthority}" nmerge -; then
    echo "ERROR: failed to install the temporary Xauthority cookie in the container." >&2
    exit 2
fi
docker exec "${CONTAINER_NAME}" chmod 0600 "${container_xauthority}"

mapfile -t tty_args < <(interactive_args)
session_id="${UID}-$$"
set +e
docker exec "${tty_args[@]}" \
    --env "DISPLAY=${DISPLAY}" \
    --env "XAUTHORITY=${container_xauthority}" \
    --env QT_X11_NO_MITSHM=1 \
    "${CONTAINER_NAME}" run-vision-debug "${session_id}"
status=$?
set -e
exit "${status}"

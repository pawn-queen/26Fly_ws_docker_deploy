#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command docker

if ! container_exists; then
    echo "Container '${CONTAINER_NAME}' does not exist."
    exit 0
fi

if container_running; then
    docker stop --time 30 "${CONTAINER_NAME}" >/dev/null
fi
echo "Stopped ${CONTAINER_NAME} through its PID-1 systemd; container and named volumes were preserved."

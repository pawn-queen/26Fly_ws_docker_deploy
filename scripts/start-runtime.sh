#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running
docker container inspect --format 'container={{.Name}} status={{.State.Status}} image={{.Config.Image}}' "${CONTAINER_NAME}"

for _ in {1..20}; do
    pid1="$(docker exec "${CONTAINER_NAME}" ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${pid1}" == "systemd" ]]; then
        echo "PID 1=systemd"
        docker exec "${CONTAINER_NAME}" systemctl --no-pager is-system-running || true
        exit 0
    fi
    sleep 0.25
done

echo "ERROR: container started, but PID 1 is not systemd." >&2
docker logs --tail 100 "${CONTAINER_NAME}" >&2 || true
exit 2

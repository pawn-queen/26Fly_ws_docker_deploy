#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running
docker container inspect --format 'container={{.Name}} status={{.State.Status}} image={{.Config.Image}}' "${CONTAINER_NAME}"

for _ in {1..40}; do
    pid1="$(
        docker exec "${CONTAINER_NAME}" \
            ps -p 1 -o comm= 2>/dev/null |
            tr -d '[:space:]' || true
    )"

    if [[ "${pid1}" == "systemd" ]]; then
        systemd_state="$(
            docker exec "${CONTAINER_NAME}" \
                systemctl --no-pager is-system-running \
                2>/dev/null || true
        )"

        case "${systemd_state}" in
            running|degraded)
                echo "PID 1=systemd"
                echo "systemd state=${systemd_state}"
                exit 0
                ;;
        esac
    fi

    sleep 0.25
done

echo "ERROR: container started, but systemd did not become ready." >&2
docker exec "${CONTAINER_NAME}" \
    journalctl -b -n 100 --no-pager >&2 || true
exit 2

#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command docker

if ! container_exists; then
    echo "container=${CONTAINER_NAME} status=absent"
    exit 0
fi

docker container inspect --format 'container={{.Name}} status={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}} privileged={{.HostConfig.Privileged}} cgroupns={{.HostConfig.CgroupnsMode}} user={{json .Config.User}}' "${CONTAINER_NAME}"

if ! container_running; then
    exit 0
fi

pid1="$(docker exec "${CONTAINER_NAME}" ps -p 1 -o comm= | tr -d '[:space:]')"
echo "pid1=${pid1}"
docker exec \
    --env SYSTEMD_COLORS=0 \
    --env SYSTEMD_PAGER=cat \
    "${CONTAINER_NAME}" \
    systemctl --no-pager --full status \
        systemd-journald.service systemd-journal-flush.service \
        micro-xrce-agent.service mavlink-routerd.service || true

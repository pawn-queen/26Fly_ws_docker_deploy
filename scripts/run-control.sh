#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${ALLOW_FLIGHT_CONTROL:-NO}" != "YES" ]]; then
    echo "REFUSED: use ALLOW_FLIGHT_CONTROL=YES only for a deliberate manual mission start." >&2
    echo "Keep propellers removed until all preflight checks pass." >&2
    exit 64
fi

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running
mapfile -t tty_args < <(interactive_args)
exec docker exec "${tty_args[@]}" \
    --env ALLOW_FLIGHT_CONTROL=YES \
    "${CONTAINER_NAME}" run-control "$@"

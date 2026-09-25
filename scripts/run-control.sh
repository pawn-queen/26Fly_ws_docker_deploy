#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${ALLOW_FLIGHT_CONTROL:-NO}" != "YES" ]]; then
    echo "REFUSED: use ALLOW_FLIGHT_CONTROL=YES only for a deliberate manual mission start." >&2
    echo "Keep propellers removed until all preflight checks pass." >&2
    exit 64
fi

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/managed-task.sh"
load_runtime_settings
run_managed_control_unit "$@"

#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running
tty_args=()
if [[ -t 0 && -t 1 ]]; then
    tty_args=(-it)
fi

exec docker exec "${tty_args[@]}" "${CONTAINER_NAME}" 26fly-shell "$@"

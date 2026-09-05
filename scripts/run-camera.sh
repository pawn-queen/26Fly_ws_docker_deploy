#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running
mapfile -t tty_args < <(interactive_args)
exec docker exec "${tty_args[@]}" "${CONTAINER_NAME}" run-camera "$@"

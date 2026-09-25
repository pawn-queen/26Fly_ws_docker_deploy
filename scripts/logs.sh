#!/usr/bin/env bash
set -Eeuo pipefail

# Pass journalctl filters through unchanged (for example -u, --since, -n, -f).
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running

exec docker exec "${CONTAINER_NAME}" journalctl --no-pager "$@"

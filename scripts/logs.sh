#!/usr/bin/env bash
set -Eeuo pipefail

# The minimal container target does not start journald. Both managed services
# inherit PID 1 stdout/stderr, so Docker is the single log transport.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running

exec docker logs "$@" "${CONTAINER_NAME}"

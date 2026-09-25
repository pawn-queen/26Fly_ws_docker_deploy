#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/managed-task.sh"
load_runtime_settings
run_managed_task_unit 26fly-detect.service detect "$@"

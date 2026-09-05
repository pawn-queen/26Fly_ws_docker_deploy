#!/usr/bin/env bash
set -Eeuo pipefail

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${deploy_dir}/scripts/run-control.sh" "$@"

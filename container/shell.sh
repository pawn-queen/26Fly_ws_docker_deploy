#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh
exec bash "$@"

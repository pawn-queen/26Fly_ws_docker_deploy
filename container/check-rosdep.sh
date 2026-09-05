#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/26fly/env.sh

if ! rosdep db >/dev/null 2>&1; then
    echo "ERROR: rosdep cache is not initialized." >&2
    echo "Run inside the runtime: rosdep update --rosdistro humble" >&2
    exit 2
fi

# Temporary exceptions mirror known-invalid entries in the current manifests.
rosdep check \
    --from-paths /workspace/src \
    --ignore-src \
    --rosdistro humble \
    --skip-keys "math time collections test_interface" \
    "$@"

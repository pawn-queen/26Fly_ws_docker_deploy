#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo 'Usage: ./scripts/deploy-bucket-logger.sh'
    echo 'Install the standalone logger into the existing runtime log volume.'
    exit 0
fi
if (( $# != 0 )); then
    echo 'ERROR: deploy-bucket-logger.sh does not accept arguments.' >&2
    exit 64
fi

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
ensure_runtime_running

logger_source="${DEPLOY_DIR}/scripts/log_bucket_ned.py"
logger_dir=/workspace/log/calibration/bin
docker exec "${CONTAINER_NAME}" mkdir -p "${logger_dir}"
docker cp "${logger_source}" "${CONTAINER_NAME}:${logger_dir}/log_bucket_ned.py.new"
docker exec "${CONTAINER_NAME}" bash -c '
    chmod 0755 "$1/log_bucket_ned.py.new"
    mv -f -- "$1/log_bucket_ned.py.new" "$1/log_bucket_ned.py"
' bash "${logger_dir}"
echo "Bucket logger deployed: ${CONTAINER_NAME}:${logger_dir}/log_bucket_ned.py" >&2

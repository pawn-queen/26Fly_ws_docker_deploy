#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings
require_command docker

base_image="$(dotenv_value BASE_IMAGE ultralytics/ultralytics:8.4.138-jetson-jetpack6)"
ultralytics_version="$(dotenv_value ULTRALYTICS_VERSION 8.4.138)"
xrce_version="$(dotenv_value XRCE_AGENT_VERSION v2.4.2)"
router_version="$(dotenv_value MAVLINK_ROUTER_VERSION v4)"

exec docker build \
    --file "${DEPLOY_DIR}/Dockerfile" \
    --platform linux/arm64 \
    --tag "${APP_IMAGE}" \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "ULTRALYTICS_VERSION=${ultralytics_version}" \
    --build-arg "XRCE_AGENT_VERSION=${xrce_version}" \
    --build-arg "MAVLINK_ROUTER_VERSION=${router_version}" \
    --build-arg "BUILD_JOBS=${BUILD_JOBS}" \
    "$@" \
    "${DEPLOY_DIR}"

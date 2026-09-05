#!/usr/bin/env bash

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DOTENV_FILE="${DEPLOY_DIR}/.env"

dotenv_value() {
    local key=$1
    local fallback=${2:-}
    local value=
    if [[ -r "${DOTENV_FILE}" ]]; then
        value="$(awk -v key="${key}" '
            index($0, key "=") == 1 { value=substr($0, length(key) + 2) }
            END { print value }
        ' "${DOTENV_FILE}")"
    fi
    value="${value%$'\r'}"
    if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s\n' "${value:-${fallback}}"
}

load_runtime_settings() {
    if [[ ! -r "${DOTENV_FILE}" ]]; then
        echo "ERROR: ${DOTENV_FILE} is missing. Run ./scripts/init-env.sh." >&2
        return 2
    fi

    CONTAINER_NAME="$(dotenv_value CONTAINER_NAME 26fly-runtime)"
    APP_IMAGE="$(dotenv_value APP_IMAGE 26fly-jetson:jp6-humble-ultralytics-8.4.138)"
    HOST_WS_SRC="$(dotenv_value HOST_WS_SRC /home/queen/uav/26Season_Fly_ws_archive/src)"
    HOST_MODEL_DIR="$(dotenv_value HOST_MODEL_DIR "${DEPLOY_DIR}/models")"
    HOST_CONFIG_DIR="$(dotenv_value HOST_CONFIG_DIR "${DEPLOY_DIR}/config")"
    VOLUME_PREFIX="$(dotenv_value VOLUME_PREFIX 26fly-jp6-humble)"
    BUILD_JOBS="$(dotenv_value BUILD_JOBS 2)"
    export CONTAINER_NAME APP_IMAGE HOST_WS_SRC HOST_MODEL_DIR HOST_CONFIG_DIR VOLUME_PREFIX BUILD_JOBS
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command is unavailable: $1" >&2
        return 2
    fi
}

container_exists() {
    docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
    [[ "$(docker container inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]
}

ensure_runtime_running() {
    require_command docker
    if ! container_exists; then
        echo "ERROR: container '${CONTAINER_NAME}' does not exist." >&2
        echo "Run ./scripts/create-runtime.sh once." >&2
        return 2
    fi
    if ! container_running; then
        docker start "${CONTAINER_NAME}" >/dev/null
    fi
}

interactive_args() {
    if [[ -t 0 && -t 1 ]]; then
        printf '%s\n' -it
    fi
}

#!/usr/bin/env bash
set -Eeuo pipefail

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
env_file="${deploy_dir}/.env"
workspace_src="$(dirname -- "${deploy_dir}")/26Season_Fly_ws_jetson/src"

if [[ -e "${env_file}" && "${1:-}" != "--force" ]]; then
    echo "${env_file} already exists; use --force to regenerate it." >&2
    exit 2
fi

temporary_file="$(mktemp "${deploy_dir}/.env.tmp.XXXXXX")"
cleanup() {
    rm -f -- "${temporary_file}"
}
trap cleanup EXIT

sed \
    -e "s|^HOST_WS_SRC=.*|HOST_WS_SRC=${workspace_src}|" \
    -e "s|^HOST_MODEL_DIR=.*|HOST_MODEL_DIR=${deploy_dir}/models|" \
    -e "s|^HOST_CONFIG_DIR=.*|HOST_CONFIG_DIR=${deploy_dir}/config|" \
    "${deploy_dir}/.env.example" > "${temporary_file}"
mv -- "${temporary_file}" "${env_file}"
trap - EXIT

echo "Wrote ${env_file}. Review paths, then edit config/runtime.env for hardware settings."

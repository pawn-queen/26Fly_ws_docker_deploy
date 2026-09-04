#!/usr/bin/env bash
set -Eeuo pipefail

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
env_file="${deploy_dir}/.env"

if [[ -e "${env_file}" && "${1:-}" != "--force" ]]; then
    echo "${env_file} already exists; use --force to regenerate it." >&2
    exit 2
fi

group_gid() {
    local name=$1
    local fallback=$2
    local entry
    entry="$(getent group "${name}" || true)"
    if [[ -n "${entry}" ]]; then
        cut -d: -f3 <<< "${entry}"
    else
        printf '%s\n' "${fallback}"
    fi
}

host_uid="$(id -u)"
host_gid="$(id -g)"
video_gid="$(group_gid video 44)"
dialout_gid="$(group_gid dialout 20)"
render_gid="$(group_gid render 110)"
plugdev_gid="$(group_gid plugdev 46)"

tmp_file="$(mktemp "${deploy_dir}/.env.tmp.XXXXXX")"
cleanup() {
    rm -f -- "${tmp_file}"
}
trap cleanup EXIT

sed \
    -e "s/^HOST_UID=.*/HOST_UID=${host_uid}/" \
    -e "s/^HOST_GID=.*/HOST_GID=${host_gid}/" \
    -e "s/^VIDEO_GID=.*/VIDEO_GID=${video_gid}/" \
    -e "s/^DIALOUT_GID=.*/DIALOUT_GID=${dialout_gid}/" \
    -e "s/^RENDER_GID=.*/RENDER_GID=${render_gid}/" \
    -e "s/^PLUGDEV_GID=.*/PLUGDEV_GID=${plugdev_gid}/" \
    -e "s|^HOST_MODEL_DIR=.*|HOST_MODEL_DIR=${deploy_dir}/models|" \
    "${deploy_dir}/.env.example" > "${tmp_file}"

mv -- "${tmp_file}" "${env_file}"
trap - EXIT
echo "Wrote ${env_file}. Review device paths and models before starting services."

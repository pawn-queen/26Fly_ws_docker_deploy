#!/usr/bin/env bash
set -Eeuo pipefail

label="${1:?usage: resolve-device LABEL PREFERRED CANDIDATES [EXCLUDE]}"
preferred="${2:-auto}"
candidates="${3:-}"
exclude="${4:-}"
timeout_seconds="${DEVICE_DISCOVERY_TIMEOUT:-15}"

if ! [[ "${timeout_seconds}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: DEVICE_DISCOVERY_TIMEOUT must be an integer." >&2
    exit 2
fi

same_device() {
    local left=$1
    local right=$2
    local left_real right_real
    [[ -n "${right}" ]] || return 1
    left_real="$(readlink -f -- "${left}" 2>/dev/null || printf '%s' "${left}")"
    right_real="$(readlink -f -- "${right}" 2>/dev/null || printf '%s' "${right}")"
    [[ "${left_real}" == "${right_real}" ]]
}

usable() {
    local path=$1
    [[ -c "${path}" && -r "${path}" && -w "${path}" ]] || return 1
    ! same_device "${path}" "${exclude}"
}

find_device() {
    local pattern path
    if [[ "${preferred}" != "auto" ]] && usable "${preferred}"; then
        printf '%s\n' "${preferred}"
        return 0
    fi

    # Word splitting and pathname expansion are intentional for the trusted list.
    # shellcheck disable=SC2086
    for pattern in ${candidates}; do
        while IFS= read -r path; do
            if usable "${path}"; then
                printf '%s\n' "${path}"
                return 0
            fi
        done < <(compgen -G "${pattern}" | sort)
    done
    return 1
}

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS <= deadline )); do
    if selected="$(find_device)"; then
        echo "${label}: selected ${selected}" >&2
        printf '%s\n' "${selected}"
        exit 0
    fi
    sleep 1
done

echo "ERROR: ${label}: no accessible character device found." >&2
echo "preferred=${preferred} candidates=${candidates} exclude=${exclude:-<none>}" >&2
exit 2

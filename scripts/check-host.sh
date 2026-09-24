#!/usr/bin/env bash
set -uo pipefail

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
load_runtime_settings || exit $?

failures=0
warnings=0
ok() { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }

runtime_value() {
    local key=$1
    local value
    value="$(awk -v key="${key}" '
        index($0, key "=") == 1 { value=substr($0, length(key) + 2) }
        END { print value }
    ' "${HOST_CONFIG_DIR}/runtime.env" 2>/dev/null)"
    value="${value%$'\r'}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "${value}"
}

container_path_to_host() {
    local path=$1
    case "${path}" in
        /workspace/src/*)
            printf '%s/%s\n' "${HOST_WS_SRC}" "${path#/workspace/src/}"
            ;;
        /workspace/models/*)
            printf '%s/%s\n' "${HOST_MODEL_DIR}" "${path#/workspace/models/}"
            ;;
        *)
            return 1
            ;;
    esac
}

if [[ "$(uname -m)" == "aarch64" ]]; then
    ok "architecture is aarch64"
else
    fail "architecture is $(uname -m); the runtime image is Jetson aarch64-only"
fi

if [[ -r /etc/nv_tegra_release ]]; then
    ok "Jetson BSP marker: $(head -n 1 /etc/nv_tegra_release)"
elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W nvidia-l4t-core >/dev/null 2>&1; then
    ok "nvidia-l4t-core is installed"
else
    fail "Jetson Linux BSP was not detected"
fi

docker_daemon_available=false
if command -v docker >/dev/null 2>&1; then
    ok "docker command is installed"
    if docker_info="$(docker info --format '{{json .Runtimes}}|{{.CgroupVersion}}' 2>/dev/null)"; then
        docker_daemon_available=true
        runtimes="${docker_info%%|*}"
        cgroup_version="${docker_info##*|}"
        if grep -q nvidia <<< "${runtimes}"; then
            ok "NVIDIA container runtime is registered"
        else
            fail "NVIDIA runtime is not visible in docker info"
        fi
        if [[ "${cgroup_version}" == "2" ]]; then
            ok "Docker uses cgroup v2"
        else
            fail "Docker cgroup version is '${cgroup_version:-unknown}'; container PID-1 systemd requires the JetPack 6 cgroup-v2 setup"
        fi
    else
        fail "docker is installed, but the daemon is not accessible (docker info failed)"
    fi
else
    fail "docker is not installed"
fi

for package_file in \
    "${HOST_WS_SRC}/detect/package.xml" \
    "${HOST_WS_SRC}/fly/package.xml" \
    "${HOST_WS_SRC}/px4_msgs/package.xml"; do
    if [[ -r "${package_file}" ]]; then
        ok "source found: ${package_file}"
    else
        fail "missing source: ${package_file}"
    fi
done

if [[ -r "${HOST_CONFIG_DIR}/runtime.env" ]]; then
    ok "runtime config is readable: ${HOST_CONFIG_DIR}/runtime.env"
    expected_px4_msgs_version="$(runtime_value PX4_MSGS_EXPECTED_VERSION)"
    pinned_px4_msgs_commit="$(runtime_value PX4_MSGS_EXPECTED_COMMIT)"
    if [[ ! "${pinned_px4_msgs_commit}" =~ ^[0-9a-f]{40}$ ]]; then
        fail "PX4_MSGS_EXPECTED_COMMIT must be a full lowercase 40-character Git commit"
    fi
    px4_msgs_dir="${HOST_WS_SRC}/px4_msgs"
    if [[ -r "${px4_msgs_dir}/package.xml" ]]; then
        actual_px4_msgs_version="$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "${px4_msgs_dir}/package.xml" | head -n 1)"
        if [[ -n "${expected_px4_msgs_version}" && "${actual_px4_msgs_version}" == "${expected_px4_msgs_version}" ]]; then
            ok "px4_msgs version is ${actual_px4_msgs_version}"
        else
            fail "px4_msgs version is '${actual_px4_msgs_version:-unknown}', expected '${expected_px4_msgs_version:-unset}'"
        fi
        if [[ -e "${px4_msgs_dir}/.git" ]]; then
            px4_msgs_commit="$(git -C "${px4_msgs_dir}" rev-parse HEAD 2>/dev/null || true)"
            if [[ -n "${px4_msgs_commit}" ]]; then
                ok "px4_msgs is a versioned checkout at ${px4_msgs_commit:0:12}"
                px4_msgs_remote="$(git -C "${px4_msgs_dir}" remote get-url origin 2>/dev/null || true)"
                if [[ "${px4_msgs_remote}" == "${PX4_MSGS_REPOSITORY}" ]]; then
                    ok "px4_msgs origin matches the configured repository"
                else
                    fail "px4_msgs origin is '${px4_msgs_remote:-unset}', expected '${PX4_MSGS_REPOSITORY}'"
                fi
                ref_px4_msgs_commit="$(git -C "${px4_msgs_dir}" rev-parse "${PX4_MSGS_REF}^{commit}" 2>/dev/null || true)"
                if [[ -n "${ref_px4_msgs_commit}" && "${ref_px4_msgs_commit}" == "${pinned_px4_msgs_commit}" ]]; then
                    ok "px4_msgs ref ${PX4_MSGS_REF} resolves to the pinned commit"
                else
                    fail "px4_msgs ref ${PX4_MSGS_REF} does not resolve to the pinned commit"
                fi
                if [[ "${px4_msgs_commit}" == "${pinned_px4_msgs_commit}" ]]; then
                    ok "px4_msgs HEAD matches the pinned commit"
                else
                    fail "px4_msgs HEAD is '${px4_msgs_commit}', expected '${pinned_px4_msgs_commit:-unset}'"
                fi
                if ! px4_msgs_status="$(git -C "${px4_msgs_dir}" status --porcelain --untracked-files=all 2>/dev/null)"; then
                    fail "px4_msgs Git status cannot be inspected"
                elif [[ -n "${px4_msgs_status}" ]]; then
                    fail "px4_msgs has local changes or untracked files"
                else
                    ok "px4_msgs checkout is clean"
                fi
            else
                fail "px4_msgs has Git metadata but its commit cannot be resolved"
            fi
        else
            fail "px4_msgs is not an independent Git checkout or submodule: ${px4_msgs_dir}"
        fi
    fi

    source_repo_root="$(git -C "${HOST_WS_SRC}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "${source_repo_root}" ]]; then
        source_commit="$(git -C "${source_repo_root}" rev-parse --short=12 HEAD 2>/dev/null || true)"
        source_branch="$(git -C "${source_repo_root}" branch --show-current 2>/dev/null || true)"
        ok "Jetson source checkout: branch=${source_branch:-detached} commit=${source_commit:-unknown}"
        if ! source_status="$(git -C "${source_repo_root}" status --porcelain --untracked-files=normal 2>/dev/null)"; then
            fail "Jetson source Git status cannot be inspected"
        elif [[ -n "${source_status}" ]]; then
            fail "Jetson source checkout has uncommitted changes; they are not available to git pull on another device"
        fi
        source_upstream="$(git -C "${source_repo_root}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
        if [[ -z "${source_upstream}" ]]; then
            warn "Jetson source checkout has no upstream; pushed state cannot be verified"
        else
            source_divergence="$(git -C "${source_repo_root}" rev-list --left-right --count "${source_upstream}...HEAD" 2>/dev/null || true)"
            read -r source_behind source_ahead <<< "${source_divergence}"
            if ! [[ "${source_behind}" =~ ^[0-9]+$ && "${source_ahead}" =~ ^[0-9]+$ ]]; then
                fail "Jetson source divergence from ${source_upstream} cannot be determined"
            elif (( source_ahead > 0 )); then
                fail "Jetson source checkout is ${source_ahead} commit(s) ahead of ${source_upstream}; push before deploying"
            elif (( source_behind > 0 )); then
                fail "Jetson source checkout is ${source_behind} commit(s) behind ${source_upstream}; pull before deploying"
            else
                ok "Jetson source HEAD matches local upstream ${source_upstream}"
            fi
        fi
    else
        fail "Jetson source directory is not inside a Git checkout: ${HOST_WS_SRC}"
    fi
    for label_and_model in \
        "Detector:$(runtime_value DETECT_MODEL)" \
        "Control:$(runtime_value CONTROL_MODEL)"; do
        label="${label_and_model%%:*}"
        container_model="${label_and_model#*:}"
        host_model="$(container_path_to_host "${container_model}" 2>/dev/null || true)"
        if [[ -z "${host_model}" ]]; then
            fail "${label} model path is outside the supported source/model mounts: ${container_model}"
            continue
        fi
        if [[ ! -r "${host_model}" ]]; then
            fail "${label} model is missing: ${host_model}"
            continue
        fi
        if [[ "${host_model}" != *.engine ]]; then
            fail "${label} model is not a Jetson TensorRT .engine file: ${host_model}"
            continue
        fi
        ok "${label} TensorRT engine exists: ${host_model}"

        if [[ "${host_model}" == "${HOST_WS_SRC}/"* ]]; then
            if [[ -z "${source_repo_root}" ]]; then
                fail "Jetson source directory is not inside a Git checkout: ${HOST_WS_SRC}"
            else
                model_relative="${host_model#"${source_repo_root}"/}"
                if git -C "${source_repo_root}" ls-files --error-unmatch -- "${model_relative}" >/dev/null 2>&1; then
                    ok "${label} engine is tracked by the Jetson source repository"
                    if git -C "${source_repo_root}" cat-file -e "HEAD:${model_relative}" 2>/dev/null; then
                        if git -C "${source_repo_root}" diff --quiet HEAD -- "${model_relative}"; then
                            ok "${label} engine matches the current Jetson source revision"
                        else
                            fail "${label} engine has changes not committed in HEAD: ${host_model}"
                        fi
                    else
                        fail "${label} engine is tracked but not committed in HEAD: ${host_model}"
                    fi
                else
                    fail "${label} engine is not tracked by Git: ${host_model}"
                fi
            fi
        fi
    done

    xrce_transport="$(runtime_value XRCE_TRANSPORT)"
    mavlink_transport="$(runtime_value MAVLINK_TRANSPORT)"
    xrce_device="$(runtime_value XRCE_SERIAL_DEVICE)"
    mavlink_device="$(runtime_value MAVLINK_SERIAL_DEVICE)"
    if [[ "${xrce_transport}" == "serial" && "${mavlink_transport}" == "serial" ]]; then
        xrce_real="$(readlink -f -- "${xrce_device}" 2>/dev/null || printf '%s' "${xrce_device}")"
        mavlink_real="$(readlink -f -- "${mavlink_device}" 2>/dev/null || printf '%s' "${mavlink_device}")"
        if [[ "${xrce_real}" == "${mavlink_real}" ]]; then
            fail "XRCE and MAVLink are configured to use the same serial device: ${xrce_device}"
        else
            ok "XRCE and MAVLink serial inputs are distinct in configuration"
        fi
        for label_and_device in "XRCE:${xrce_device}" "MAVLink:${mavlink_device}"; do
            label="${label_and_device%%:*}"
            device="${label_and_device#*:}"
            if [[ -c "${device}" ]]; then
                ok "${label} serial device exists: ${device}"
            else
                fail "${label} serial device is absent; no ttyACM fallback is allowed: ${device}"
            fi
        done
    fi

    realsense_hint="$(runtime_value REALSENSE_CAMERA_HINT)"
    if command -v v4l2-ctl >/dev/null 2>&1; then
        camera_listing="$(v4l2-ctl --list-devices 2>/dev/null || true)"
        if awk -v hint="${realsense_hint:-RealSense}" '
            /^[^[:space:]]/ { matched = index($0, hint) > 0; next }
            matched {
                device = $0
                sub(/^[[:space:]]+/, "", device)
                if (device ~ /^\/dev\/video[0-9]+$/) found = 1
            }
            END { exit(found ? 0 : 1) }
        ' <<< "${camera_listing}"; then
            ok "RealSense video group is present"
        else
            fail "no RealSense video group matched hint '${realsense_hint:-RealSense}'"
        fi
    else
        fail "v4l2-ctl is unavailable on the host; camera identities cannot be checked"
    fi

    wide_camera_device="$(runtime_value WIDE_CAMERA_DEVICE)"
    wide_camera_hint="$(runtime_value CONTROL_CAMERA_HINT)"
    wide_camera_real=""
    if [[ -n "${wide_camera_device}" ]]; then
        wide_camera_real="$(readlink -f -- "${wide_camera_device}" 2>/dev/null || true)"
    fi
    if [[ -c "${wide_camera_device}" ]]; then
        ok "wide camera device exists: ${wide_camera_device}"
        if command -v v4l2-ctl >/dev/null 2>&1; then
            camera_listing="$(v4l2-ctl --list-devices 2>/dev/null || true)"
            if awk -v hint="${wide_camera_hint}" -v wanted="${wide_camera_real}" '
                /^[^[:space:]]/ { matched = index($0, hint) > 0; next }
                matched && !seen {
                    device = $0
                    sub(/^[[:space:]]+/, "", device)
                    if (device ~ /^\/dev\/video[0-9]+$/) {
                        first = device
                        seen = 1
                    }
                }
                END { exit(seen && first == wanted ? 0 : 1) }
            ' <<< "${camera_listing}"; then
                ok "camera hint '${wide_camera_hint}' selects ${wide_camera_device} -> ${wide_camera_real} as its first video node"
            else
                fail "camera hint '${wide_camera_hint}' does not select ${wide_camera_device} -> ${wide_camera_real} as its first video node"
            fi
            if v4l2-ctl --device "${wide_camera_device}" --list-formats-ext >/dev/null 2>&1; then
                ok "wide camera exposes V4L2 capture formats: ${wide_camera_device}"
            else
                fail "wide camera does not expose usable V4L2 capture formats: ${wide_camera_device}"
            fi
        else
            warn "v4l2-ctl is unavailable on the host; wide-camera identity was not checked"
        fi
    else
        fail "wide camera device is absent: ${wide_camera_device}"
    fi
else
    fail "runtime config is missing: ${HOST_CONFIG_DIR}/runtime.env"
fi

if [[ -d /dev/bus/usb ]]; then
    ok "/dev/bus/usb exists"
else
    fail "/dev/bus/usb is absent; RealSense will not be available"
fi

if [[ "${docker_daemon_available}" == "true" ]] && container_exists; then
    container_image_id="$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    expected_image_id="$(docker image inspect --format '{{.Id}}' "${APP_IMAGE}" 2>/dev/null || true)"
    privileged="$(docker inspect --format '{{.HostConfig.Privileged}}' "${CONTAINER_NAME}")"
    runtime="$(docker inspect --format '{{.HostConfig.Runtime}}' "${CONTAINER_NAME}")"
    cgroup_namespace="$(docker inspect --format '{{.HostConfig.CgroupnsMode}}' "${CONTAINER_NAME}")"
    entrypoint="$(docker inspect --format '{{json .Config.Entrypoint}}' "${CONTAINER_NAME}")"
    command="$(docker inspect --format '{{json .Config.Cmd}}' "${CONTAINER_NAME}")"
    pid_mode="$(docker inspect --format '{{.HostConfig.PidMode}}' "${CONTAINER_NAME}")"
    user="$(docker inspect --format '{{.Config.User}}' "${CONTAINER_NAME}")"
    mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s|%t|%s|%s|%s\n" .Destination .RW .Type .Source .Name}}{{end}}' "${CONTAINER_NAME}")"

    mount_record() {
        local destination=$1
        awk -F'|' -v destination="${destination}" '$1 == destination {
            print $2 "|" $3 "|" $4 "|" $5
            exit
        }' <<< "${mounts}"
    }

    check_bind_mount() {
        local destination=$1
        local expected_source=$2
        local expected_rw=$3
        local record rw type source
        record="$(mount_record "${destination}")"
        IFS='|' read -r rw type source _ <<< "${record}"
        if [[ "${rw}" == "${expected_rw}" && "${type}" == "bind" && "${source}" == "${expected_source}" ]]; then
            ok "${destination} bind mount matches ${expected_source} (rw=${expected_rw})"
        else
            fail "${destination} mount is '${record:-missing}', expected '${expected_rw}|bind|${expected_source}|'"
        fi
    }

    check_named_volume() {
        local destination=$1
        local expected_name=$2
        local record rw type name
        record="$(mount_record "${destination}")"
        IFS='|' read -r rw type _ name <<< "${record}"
        if [[ "${rw}" == "true" && "${type}" == "volume" && "${name}" == "${expected_name}" ]]; then
            ok "${destination} uses named volume ${expected_name}"
        else
            fail "${destination} mount is '${record:-missing}', expected named volume '${expected_name}'"
        fi
    }

    if [[ -n "${expected_image_id}" && "${container_image_id}" == "${expected_image_id}" ]]; then
        ok "runtime uses the current ${APP_IMAGE} image ID"
    else
        fail "runtime image ID '${container_image_id:-unknown}' does not match current ${APP_IMAGE} ('${expected_image_id:-missing}')"
    fi
    if [[ "${privileged}" == "true" ]]; then ok "runtime is privileged"; else fail "runtime is not privileged"; fi
    if [[ "${runtime}" == "nvidia" ]]; then ok "runtime uses NVIDIA container runtime"; else fail "container runtime is '${runtime}'"; fi
    if [[ "${cgroup_namespace}" == "private" ]]; then ok "runtime uses a private cgroup namespace"; else fail "cgroup namespace is '${cgroup_namespace}'"; fi
    if [[ "${entrypoint}" == '["/sbin/init"]' ]]; then ok "container entrypoint is /sbin/init"; else fail "container entrypoint is ${entrypoint}"; fi
    if [[ "${command}" == '["--unit=26fly.target"]' ]]; then ok "systemd boots 26fly.target"; else fail "container command is ${command}"; fi
    if [[ -z "${pid_mode}" ]]; then ok "runtime has a private PID namespace"; else fail "PID namespace mode is '${pid_mode}'"; fi
    if [[ -z "${user}" || "${user}" == "root" || "${user}" == "0" ]]; then ok "runtime user is root"; else fail "runtime user is '${user}'"; fi
    check_bind_mount /dev /dev true
    check_bind_mount /workspace/src "${HOST_WS_SRC}" false
    check_bind_mount /workspace/models "${HOST_MODEL_DIR}" false
    check_bind_mount /etc/26fly "${HOST_CONFIG_DIR}" false
    check_named_volume /workspace/build "${VOLUME_PREFIX}-build"
    check_named_volume /workspace/install "${VOLUME_PREFIX}-install"
    check_named_volume /workspace/log "${VOLUME_PREFIX}-log"
    if container_running; then
        pid1="$(docker exec "${CONTAINER_NAME}" ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${pid1}" == "systemd" ]]; then ok "container PID 1 is systemd"; else fail "container PID 1 is '${pid1:-unknown}'"; fi
    fi
else
    warn "persistent container '${CONTAINER_NAME}' has not been created yet"
fi

printf '\nHost check: %d failure(s), %d warning(s).\n' "${failures}" "${warnings}"
(( failures == 0 ))

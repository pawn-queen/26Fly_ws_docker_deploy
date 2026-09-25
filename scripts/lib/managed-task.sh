#!/usr/bin/env bash

# This file is sourced by the host camera/detect/control wrappers after
# runtime.sh.  The foreground log follower keeps the container log attached to
# the operator terminal while systemd owns each task process group.

_managed_task_systemctl() {
    docker exec \
        --env SYSTEMD_COLORS=1 \
        --env SYSTEMD_PAGER=cat \
        "${_MANAGED_TASK_CONTAINER}" \
        systemctl --no-pager "$@"
}

_managed_task_wait_for_systemd() {
    local systemd_state=

    for _ in {1..40}; do
        systemd_state="$(
            docker exec "${_MANAGED_TASK_CONTAINER}" \
                systemctl --no-pager is-system-running \
                2>/dev/null || true
        )"
        case "${systemd_state}" in
            running|degraded) return 0 ;;
        esac
        sleep 0.25
    done

    echo "ERROR: container systemd did not become ready (state=${systemd_state:-unknown})." >&2
    return 2
}

_managed_task_stop_logs() {
    if [[ -n "${_MANAGED_TASK_LOG_PID}" ]]; then
        kill -TERM "${_MANAGED_TASK_LOG_PID}" 2>/dev/null || true
        wait "${_MANAGED_TASK_LOG_PID}" 2>/dev/null || true
        _MANAGED_TASK_LOG_PID=
    fi
}

_managed_task_read_unit_property() {
    local property=$1

    _managed_task_read_unit_property_checked "${property}" || true
}

_managed_task_read_unit_property_checked() {
    local property=$1

    _managed_task_systemctl show \
        --property="${property}" \
        --value \
        "${_MANAGED_TASK_UNIT}" 2>/dev/null
}

_managed_task_wait_for_unit_identity() {
    local description load_state

    for _ in {1..40}; do
        if ! load_state="$(_managed_task_read_unit_property_checked LoadState)"; then
            sleep 0.1 || true
            continue
        fi
        if [[ "${load_state}" == "not-found" ]]; then
            return 4
        fi
        if [[ "${load_state}" != "loaded" ]]; then
            sleep 0.1 || true
            continue
        fi

        if description="$(_managed_task_read_unit_property_checked Description)"; then
            if [[ "${description}" == "${_MANAGED_TASK_OWNER_TOKEN}" ]]; then
                return 0
            fi
            if [[ -n "${description}" ]]; then
                return 3
            fi
        fi
        sleep 0.1 || true
    done

    return 1
}

_managed_task_claim_token_unit() {
    local identity_status

    if [[ -z "${_MANAGED_TASK_OWNER_TOKEN:-}" ]]; then
        return 1
    fi

    if _managed_task_wait_for_unit_identity; then
        _MANAGED_TASK_OWNS_UNIT=true
        return 0
    else
        identity_status=$?
    fi
    return "${identity_status}"
}

_managed_task_unit_is_stopped() {
    local load_state active_state main_pid

    load_state="$(_managed_task_read_unit_property LoadState)"
    active_state="$(_managed_task_read_unit_property ActiveState)"
    main_pid="$(_managed_task_read_unit_property MainPID)"

    # An empty value means the Docker/systemctl query failed, not that the
    # unit disappeared.  Treat only systemd's explicit not-found state as an
    # unloaded (and therefore stopped) unit.
    if [[ "${load_state}" == "not-found" ]]; then
        return 0
    fi

    case "${load_state}:${active_state}" in
        loaded:inactive|loaded:failed)
            [[ "${main_pid}" == "0" ]]
            ;;
        *) return 1 ;;
    esac
}

_managed_task_role_lock_is_free() {
    local role=$1

    case "${role}" in
        camera|detect|control) ;;
        *) return 2 ;;
    esac

    docker exec "${_MANAGED_TASK_CONTAINER}" sh -c '
        lock=/run/lock/26fly/$1.lock
        if [ ! -e "$lock" ]; then
            exit 0
        fi
        exec flock --nonblock "$lock" true
    ' sh "${role}" >/dev/null 2>&1
}

_managed_task_unit_cgroup_is_empty() {
    local load_state control_group

    if ! load_state="$(_managed_task_read_unit_property_checked LoadState)"; then
        return 1
    fi
    if [[ "${load_state}" == "not-found" ]]; then
        return 0
    fi
    if [[ "${load_state}" != "loaded" ]]; then
        return 1
    fi
    control_group=${_MANAGED_TASK_CONTROL_GROUP:-}
    if [[ -z "${control_group}" ]]; then
        if ! control_group="$(_managed_task_read_unit_property_checked ControlGroup)"; then
            return 1
        fi
    fi

    # A successfully stopped loaded unit can already have no cgroup.  If a
    # path remains, inspect the actual cgroup rather than trusting MainPID=0;
    # descendants can outlive the main process.
    if [[ -z "${control_group}" ]]; then
        return 0
    fi

    docker exec "${_MANAGED_TASK_CONTAINER}" sh -c '
        cg=$1
        case "$cg" in
            /*) ;;
            *) exit 2 ;;
        esac
        case "/$cg/" in
            */../*|*/./*) exit 2 ;;
        esac
        if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
            dir=/sys/fs/cgroup${cg}
            [ -e "$dir" ] || exit 0
            events=$dir/cgroup.events
            [ -r "$events" ] || exit 2
            grep -qx "populated 0" "$events"
        elif [ -d /sys/fs/cgroup/systemd ]; then
            dir=/sys/fs/cgroup/systemd${cg}
            [ -d "$dir" ] || exit 0
            found=false
            for procs in $(find "$dir" -type f \( -name tasks -o -name cgroup.procs \)); do
                found=true
                if IFS= read -r _pid < "$procs"; then
                    exit 1
                fi
            done
            [ "$found" = true ] || exit 2
        else
            exit 2
        fi
    ' sh "${control_group}" >/dev/null 2>&1
}

_managed_task_stop_unit() {
    local identity_status load_state

    if [[ "${_MANAGED_TASK_OWNS_UNIT}" != "true" || "${_MANAGED_TASK_STOPPING}" == "true" ]]; then
        return 0
    fi

    _MANAGED_TASK_STOPPING=true

    # Transient units use a per-launch Description token.  Never stop a unit
    # merely because its fixed name matches: another wrapper may have won a
    # concurrent start attempt.
    if [[ -n "${_MANAGED_TASK_OWNER_TOKEN:-}" ]]; then
        if _managed_task_wait_for_unit_identity; then
            identity_status=0
        else
            identity_status=$?
        fi
        if (( identity_status == 4 )) && \
            load_state="$(_managed_task_read_unit_property_checked LoadState)" && \
            [[ "${load_state}" == "not-found" ]]; then
            _MANAGED_TASK_OWNS_UNIT=false
            _MANAGED_TASK_STOP_CONFIRMED=true
            _MANAGED_TASK_STOPPING=false
            return 0
        fi
        if (( identity_status != 0 )); then
            echo "ERROR: ownership of ${_MANAGED_TASK_UNIT} cannot be verified; refusing to stop an unknown unit." >&2
            _MANAGED_TASK_STOPPING=false
            return 1
        fi
    fi

    echo "Stopping ${_MANAGED_TASK_LABEL} with SIGINT through container systemd..." >&2
    if _managed_task_systemctl stop "${_MANAGED_TASK_UNIT}"; then
        _MANAGED_TASK_OWNS_UNIT=false
        _MANAGED_TASK_STOP_CONFIRMED=true
    else
        echo "ERROR: failed to stop ${_MANAGED_TASK_UNIT}; check the container immediately." >&2
        _MANAGED_TASK_STOPPING=false
        return 1
    fi
    _MANAGED_TASK_STOPPING=false
}

_managed_task_cleanup() {
    local original_status=$?
    local launch_status

    trap - EXIT
    trap '' INT TERM HUP

    # If an unexpected shell error occurs while a transient unit is still
    # being registered, first reap the signal-immune launcher and then adopt
    # the unit only when its unique token proves that it belongs to us.
    if [[ "${_MANAGED_TASK_LAUNCHING:-false}" == "true" && -n "${_MANAGED_TASK_WAIT_PID}" ]]; then
        if wait "${_MANAGED_TASK_WAIT_PID}" 2>/dev/null; then
            launch_status=0
        else
            launch_status=$?
        fi
        _MANAGED_TASK_WAIT_PID=
        _MANAGED_TASK_LAUNCHING=false
        if [[ -z "${_MANAGED_TASK_OWNER_TOKEN:-}" ]]; then
            # Static units were confirmed inactive before their isolated start
            # launcher was submitted, so cleanup owns the matching stop.
            _MANAGED_TASK_OWNS_UNIT=true
        elif (( launch_status == 0 )); then
            _MANAGED_TASK_OWNS_UNIT=true
        else
            _managed_task_claim_token_unit || true
        fi
    fi

    if [[ "${_MANAGED_TASK_REGISTRATION_UNKNOWN:-false}" == "true" && \
        "${_MANAGED_TASK_OWNS_UNIT}" != "true" ]]; then
        _managed_task_claim_token_unit || true
    fi

    _managed_task_stop_unit || true
    if [[ -n "${_MANAGED_TASK_WAIT_PID}" ]]; then
        if [[ "${_MANAGED_TASK_OWNS_UNIT}" == "true" ]]; then
            # The explicit stop failed.  Do not leave the host wrapper blocked
            # forever in `systemctl --wait`; terminating this Docker client does
            # not pretend that the container service was stopped.
            kill -TERM "${_MANAGED_TASK_WAIT_PID}" 2>/dev/null || true
        fi
        wait "${_MANAGED_TASK_WAIT_PID}" 2>/dev/null || true
        _MANAGED_TASK_WAIT_PID=
    fi
    _managed_task_stop_logs
    return "${original_status}"
}

_managed_task_handle_signal() {
    local exit_status=$1
    local signal_name=$2

    if (( _MANAGED_TASK_SIGNAL_STATUS == 0 )); then
        _MANAGED_TASK_SIGNAL_STATUS=${exit_status}
        if [[ "${_MANAGED_TASK_OWNS_UNIT}" == "true" ]]; then
            echo "Received ${signal_name}; requesting an explicit systemctl stop for ${_MANAGED_TASK_UNIT}." >&2
            _managed_task_stop_unit || true
        elif [[ "${_MANAGED_TASK_LAUNCHING:-false}" == "true" ]]; then
            echo "Received ${signal_name}; waiting for ${_MANAGED_TASK_UNIT} registration before stopping it." >&2
        fi
    fi
}

run_managed_task_unit() {
    local unit_name=$1
    local task_label=$2
    local load_state active_state sub_state unit_result exec_status launch_status
    local stop_verified=false
    shift 2

    if (( $# != 0 )); then
        echo "ERROR: ${task_label} is now managed by a fixed systemd unit and does not accept per-invocation arguments." >&2
        echo "Set persistent task options in config/runtime.env." >&2
        return 64
    fi

    ensure_runtime_running
    require_command setsid
    require_command timeout

    _MANAGED_TASK_UNIT=${unit_name}
    _MANAGED_TASK_LABEL=${task_label}
    _MANAGED_TASK_CONTAINER=${CONTAINER_NAME}
    _MANAGED_TASK_OWNS_UNIT=false
    _MANAGED_TASK_STOPPING=false
    _MANAGED_TASK_STOP_CONFIRMED=false
    _MANAGED_TASK_LAUNCHING=false
    _MANAGED_TASK_REGISTRATION_UNKNOWN=false
    _MANAGED_TASK_OWNER_TOKEN=
    _MANAGED_TASK_CONTROL_GROUP=
    _MANAGED_TASK_LOG_PID=
    _MANAGED_TASK_WAIT_PID=
    _MANAGED_TASK_SIGNAL_STATUS=0

    _managed_task_wait_for_systemd

    load_state="$(_managed_task_systemctl show --property=LoadState --value "${unit_name}")"
    if [[ "${load_state}" != "loaded" ]]; then
        echo "ERROR: ${unit_name} is not loaded in ${CONTAINER_NAME}; rebuild the image and migrate the container." >&2
        return 2
    fi

    active_state="$(_managed_task_systemctl show --property=ActiveState --value "${unit_name}")"
    case "${active_state}" in
        active|activating|reloading|deactivating)
            echo "REFUSED: ${unit_name} is already ${active_state}; a second ${task_label} wrapper will not attach to it." >&2
            return 3
            ;;
        inactive|failed) ;;
        *)
            echo "ERROR: unexpected ${unit_name} state: ${active_state:-unknown}" >&2
            return 2
            ;;
    esac

    trap _managed_task_cleanup EXIT
    trap '_managed_task_handle_signal 130 SIGINT' INT
    trap '_managed_task_handle_signal 143 SIGTERM' TERM
    trap '_managed_task_handle_signal 129 SIGHUP' HUP

    docker logs --follow --tail 0 "${CONTAINER_NAME}" &
    _MANAGED_TASK_LOG_PID=$!

    echo "Starting ${task_label} as ${unit_name}; press Ctrl-C to stop it." >&2
    _MANAGED_TASK_LAUNCHING=true
    (
        # Do not let the terminal signal kill the start client before systemd
        # has accepted or rejected the job.  The wrapper records the signal
        # and submits an ordered stop as soon as this registration barrier ends.
        trap '' INT TERM HUP
        exec setsid --fork --wait \
            timeout --signal=TERM --kill-after=5s 30s \
            docker exec \
            --env SYSTEMD_COLORS=1 \
            --env SYSTEMD_PAGER=cat \
            "${CONTAINER_NAME}" \
            systemctl --no-pager start "${unit_name}"
    ) &
    _MANAGED_TASK_WAIT_PID=$!

    while true; do
        if wait "${_MANAGED_TASK_WAIT_PID}"; then
            launch_status=0
            break
        else
            launch_status=$?
        fi
        if kill -0 "${_MANAGED_TASK_WAIT_PID}" 2>/dev/null; then
            continue
        fi
        break
    done

    _MANAGED_TASK_WAIT_PID=
    _MANAGED_TASK_LAUNCHING=false
    # The static unit was verified inactive before this isolated start request.
    # Even a lost client response must be followed by our explicit stop.
    _MANAGED_TASK_OWNS_UNIT=true
    _MANAGED_TASK_CONTROL_GROUP="$(_managed_task_read_unit_property ControlGroup)" || \
        _MANAGED_TASK_CONTROL_GROUP=

    if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
        _managed_task_stop_unit || true
    elif (( launch_status != 0 )); then
        echo "ERROR: systemctl could not start ${unit_name} (status=${launch_status}); forcing a stop before returning." >&2
    else
        while true; do
            active_state="$(_managed_task_read_unit_property ActiveState)" || active_state=
            if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
                break
            fi
            case "${active_state}" in
                active)
                    sub_state="$(_managed_task_read_unit_property SubState)" || sub_state=
                    if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
                        break
                    fi
                    if [[ "${sub_state}" == "exited" ]]; then
                        break
                    fi
                    sleep 0.25 || true
                    ;;
                activating|reloading|deactivating)
                    sleep 0.25 || true
                    ;;
                inactive|failed) break ;;
                *)
                    echo "ERROR: lost ${unit_name} state while it was owned; forcing cleanup." >&2
                    launch_status=70
                    break
                    ;;
            esac
        done
    fi

    unit_result="$(_managed_task_read_unit_property Result)" || unit_result=
    exec_status="$(_managed_task_read_unit_property ExecMainStatus)" || exec_status=

    if [[ "${_MANAGED_TASK_OWNS_UNIT}" == "true" ]]; then
        _managed_task_stop_unit || true
    fi

    if [[ "${_MANAGED_TASK_STOP_CONFIRMED}" == "true" ]] && \
        _managed_task_unit_is_stopped && \
        _managed_task_unit_cgroup_is_empty && \
        _managed_task_role_lock_is_free "${task_label}"; then
        stop_verified=true
    fi

    _managed_task_stop_logs

    if [[ "${stop_verified}" != "true" ]]; then
        echo "ERROR: cannot confirm that ${task_label} is fully stopped; inspect ${unit_name} immediately." >&2
        return 70
    fi

    _managed_task_systemctl reset-failed "${unit_name}" >/dev/null 2>&1 || true
    trap - EXIT INT TERM HUP

    if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
        echo "${task_label} stopped completely after the terminal signal." >&2
        return "${_MANAGED_TASK_SIGNAL_STATUS}"
    fi

    if (( launch_status != 0 )) || [[ "${unit_result}" != "success" ]]; then
        echo "ERROR: ${unit_name} stopped with result=${unit_result:-unknown}, status=${exec_status:-unknown}." >&2
        _managed_task_systemctl --full status "${unit_name}" || true
        if [[ "${exec_status}" =~ ^[1-9][0-9]*$ ]] && (( exec_status <= 255 )); then
            return "${exec_status}"
        fi
        if (( launch_status > 0 && launch_status <= 255 )); then
            return "${launch_status}"
        fi
        return 1
    fi

    echo "${task_label} stopped cleanly." >&2
    return 0
}

run_managed_control_unit() {
    local unit_name=26fly-control.service
    local active_state sub_state claim_status=0 launch_status unit_result exec_status
    local final_status=0 stop_verified=false
    local owner_id owner_description

    ensure_runtime_running
    require_command setsid
    require_command timeout

    _MANAGED_TASK_UNIT=${unit_name}
    _MANAGED_TASK_LABEL=control
    _MANAGED_TASK_CONTAINER=${CONTAINER_NAME}
    _MANAGED_TASK_OWNS_UNIT=false
    _MANAGED_TASK_STOPPING=false
    _MANAGED_TASK_STOP_CONFIRMED=false
    _MANAGED_TASK_LAUNCHING=false
    _MANAGED_TASK_REGISTRATION_UNKNOWN=false
    _MANAGED_TASK_CONTROL_GROUP=
    _MANAGED_TASK_LOG_PID=
    _MANAGED_TASK_WAIT_PID=
    _MANAGED_TASK_SIGNAL_STATUS=0

    owner_id="${BASHPID}-${RANDOM}-${RANDOM}-$(date +%s%N)"
    owner_description="26Fly control owner=${owner_id}"
    _MANAGED_TASK_OWNER_TOKEN=${owner_description}

    _managed_task_wait_for_systemd

    active_state="$(_managed_task_systemctl show --property=ActiveState --value "${unit_name}" 2>/dev/null || true)"
    case "${active_state}" in
        active|activating|reloading|deactivating)
            echo "REFUSED: ${unit_name} is already ${active_state}; a second control process will not be started." >&2
            return 3
            ;;
        ""|inactive|failed) ;;
        *)
            echo "ERROR: unexpected ${unit_name} state: ${active_state}" >&2
            return 2
            ;;
    esac

    trap _managed_task_cleanup EXIT
    trap '_managed_task_handle_signal 130 SIGINT' INT
    trap '_managed_task_handle_signal 143 SIGTERM' TERM
    trap '_managed_task_handle_signal 129 SIGHUP' HUP

    docker logs --follow --tail 0 "${CONTAINER_NAME}" &
    _MANAGED_TASK_LOG_PID=$!

    echo "Starting control as transient ${unit_name}; press Ctrl-C to stop it completely." >&2
    _MANAGED_TASK_LAUNCHING=true
    (
        # The launcher must survive terminal signals until systemd has either
        # atomically created this exact unit or definitively rejected it.
        trap '' INT TERM HUP
        exec setsid --fork --wait \
            timeout --signal=TERM --kill-after=5s 30s \
            docker exec \
            --env SYSTEMD_COLORS=1 \
            --env SYSTEMD_PAGER=cat \
            "${CONTAINER_NAME}" \
            systemd-run \
            --quiet \
            --unit="${unit_name}" \
            --description="${owner_description}" \
            --service-type=exec \
            --working-directory=/workspace \
            --setenv=ALLOW_FLIGHT_CONTROL=YES \
            --property=DefaultDependencies=no \
            --property=Conflicts=shutdown.target \
            --property=Before=shutdown.target \
            --property=Restart=no \
            --property=RemainAfterExit=yes \
            --property=KillMode=control-group \
            --property=KillSignal=SIGINT \
            --property=SendSIGKILL=yes \
            --property=TimeoutStopSec=15s \
            --property=StandardOutput=file:/proc/1/fd/1 \
            --property=StandardError=file:/proc/1/fd/2 \
            -- /usr/local/bin/run-control "$@"
    ) &
    _MANAGED_TASK_WAIT_PID=$!

    # `wait` may itself be interrupted by our trap.  Retry until the launcher
    # is actually reaped; it ignores INT/TERM/HUP by design.
    while true; do
        if wait "${_MANAGED_TASK_WAIT_PID}"; then
            launch_status=0
            break
        else
            launch_status=$?
        fi
        if kill -0 "${_MANAGED_TASK_WAIT_PID}" 2>/dev/null; then
            continue
        fi
        break
    done

    _MANAGED_TASK_WAIT_PID=
    _MANAGED_TASK_LAUNCHING=false
    if (( launch_status == 0 )); then
        # A successful fixed-name StartTransientUnit call is atomic ownership
        # proof.  RemainAfterExit keeps that name reserved until our stop.
        _MANAGED_TASK_OWNS_UNIT=true
    else
        if _managed_task_claim_token_unit; then
            claim_status=0
        else
            claim_status=$?
        fi
    fi

    if [[ "${_MANAGED_TASK_OWNS_UNIT}" != "true" ]]; then
        _managed_task_stop_logs
        case "${claim_status}" in
            3)
                trap - EXIT INT TERM HUP
                echo "REFUSED: ${unit_name} belongs to another launcher; this wrapper did not stop it." >&2
                return 3
                ;;
            4)
                trap - EXIT INT TERM HUP
                echo "ERROR: systemd did not register this control unit (systemd-run status=${launch_status})." >&2
                if (( launch_status > 0 && launch_status <= 255 )); then
                    return "${launch_status}"
                fi
                return 1
                ;;
            *)
                # Keep the EXIT cleanup trap armed: the registration result is
                # unknown, so cleanup gets another token-based chance to stop
                # a unit that may have been created before the connection failed.
                _MANAGED_TASK_REGISTRATION_UNKNOWN=true
                echo "ERROR: cannot determine whether systemd registered this control unit; refusing to report it stopped." >&2
                return 70
                ;;
        esac
    fi

    _MANAGED_TASK_CONTROL_GROUP="$(_managed_task_read_unit_property ControlGroup)" || \
        _MANAGED_TASK_CONTROL_GROUP=

    # A signal received during registration is intentionally handled only
    # after ownership is proven, closing the stop-before-create race.
    if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
        _managed_task_stop_unit || true
    elif (( launch_status != 0 )); then
        echo "ERROR: ${unit_name} was created but failed to start (systemd-run status=${launch_status})." >&2
    else
        while true; do
            active_state="$(_managed_task_read_unit_property ActiveState)" || active_state=
            if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
                break
            fi
            case "${active_state}" in
                active)
                    sub_state="$(_managed_task_read_unit_property SubState)" || sub_state=
                    if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
                        break
                    fi
                    if [[ "${sub_state}" == "exited" ]]; then
                        break
                    fi
                    sleep 0.25 || true
                    ;;
                activating|reloading|deactivating)
                    sleep 0.25 || true
                    ;;
                inactive|failed) break ;;
                *)
                    echo "ERROR: lost ${unit_name} state while it was owned; forcing cleanup." >&2
                    final_status=70
                    break
                    ;;
            esac

            if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
                break
            fi
        done
    fi

    unit_result="$(_managed_task_read_unit_property Result)" || unit_result=
    exec_status="$(_managed_task_read_unit_property ExecMainStatus)" || exec_status=

    if [[ "${_MANAGED_TASK_OWNS_UNIT}" == "true" ]]; then
        _managed_task_stop_unit || true
    fi

    if [[ "${_MANAGED_TASK_STOP_CONFIRMED}" == "true" ]] && \
        _managed_task_unit_is_stopped && \
        _managed_task_unit_cgroup_is_empty && \
        _managed_task_role_lock_is_free control; then
        stop_verified=true
    fi

    _managed_task_stop_logs

    if [[ "${stop_verified}" != "true" ]]; then
        echo "ERROR: cannot confirm that control is fully stopped; inspect ${unit_name} immediately." >&2
        return 70
    fi

    # Failed transient units are retained until their failed state is reset.
    # The result/status above have already been captured, so release the fixed
    # name now for the next deliberate invocation.
    _managed_task_systemctl reset-failed "${unit_name}" >/dev/null 2>&1 || true

    trap - EXIT INT TERM HUP

    if (( _MANAGED_TASK_SIGNAL_STATUS != 0 )); then
        echo "control stopped completely after the terminal signal." >&2
        return "${_MANAGED_TASK_SIGNAL_STATUS}"
    fi

    if (( final_status != 0 )); then
        return "${final_status}"
    fi

    if (( launch_status != 0 )) || [[ "${unit_result}" != "success" ]]; then
        echo "ERROR: ${unit_name} stopped with result=${unit_result:-unknown}, status=${exec_status:-unknown}." >&2
        _managed_task_systemctl --full status "${unit_name}" || true
        if [[ "${exec_status}" =~ ^[1-9][0-9]*$ ]] && (( exec_status <= 255 )); then
            return "${exec_status}"
        fi
        if (( launch_status > 0 && launch_status <= 255 )); then
            return "${launch_status}"
        fi
        return 1
    fi

    echo "control stopped cleanly." >&2
    return 0
}

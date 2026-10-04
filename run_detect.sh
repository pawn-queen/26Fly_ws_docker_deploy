#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 0 )); then
    echo "ERROR: run_detect.sh does not accept arguments." >&2
    exit 64
fi

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${deploy_dir}/scripts/lib/runtime.sh"

camera_pid=
viewer_pid=
signal_status=0

job_is_running() {
    local expected_pid=$1 running_pid
    while IFS= read -r running_pid; do
        [[ "${running_pid}" == "${expected_pid}" ]] && return 0
    done < <(jobs -pr)
    return 1
}

record_signal() {
    # Finish registering a just-launched child before handling the stop.
    if (( signal_status == 0 )); then
        signal_status=$1
    fi
}

exit_if_signalled() {
    if (( signal_status != 0 )); then
        exit "${signal_status}"
    fi
}

cleanup() {
    local original_status=$? pid
    trap - EXIT
    trap '' INT TERM HUP
    if (( signal_status != 0 )); then
        original_status=${signal_status}
    fi

    # Only our wrappers own the task units and viewer session. Let their
    # TERM handlers stop those resources, including during startup.
    for pid in "${viewer_pid}" "${camera_pid}"; do
        if [[ -n "${pid}" ]] && job_is_running "${pid}"; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    for pid in "${viewer_pid}" "${camera_pid}"; do
        if [[ -n "${pid}" ]]; then
            wait "${pid}" 2>/dev/null || true
        fi
    done
    exit "${original_status}"
}

trap cleanup EXIT
trap 'record_signal 130' INT
trap 'record_signal 143' TERM
trap 'record_signal 129' HUP

load_runtime_settings
exit_if_signalled
# Start the container once before the two wrappers perform their own checks.
ensure_runtime_running
exit_if_signalled

echo "Starting camera/detector and both display windows. Press Ctrl-C to stop this session's vision services."
"${deploy_dir}/start_camera.sh" &
camera_pid=$!
exit_if_signalled
"${deploy_dir}/scripts/run-vision-debug.sh" &
viewer_pid=$!
exit_if_signalled

while true; do
    exit_if_signalled
    if ! job_is_running "${camera_pid}"; then
        if wait "${camera_pid}"; then component_status=0; else component_status=$?; fi
        camera_pid=
        if (( component_status == 0 )); then
            echo "Camera/detector wrapper exited; stopping this session's remaining viewer."
        else
            echo "ERROR: camera/detector wrapper exited with status ${component_status}; stopping this session's remaining viewer." >&2
        fi
        exit "${component_status}"
    fi
    if [[ -n "${viewer_pid}" ]] && ! job_is_running "${viewer_pid}"; then
        if wait "${viewer_pid}"; then component_status=0; else component_status=$?; fi
        viewer_pid=
        if (( component_status != 0 )); then
            echo "ERROR: viewer wrapper exited with status ${component_status}; stopping this session's camera/detector." >&2
            exit "${component_status}"
        fi
        echo "Display windows closed; camera/detector continue running. Press Ctrl-C here to stop them."
        echo "To reopen the displays, run ./scripts/run-vision-debug.sh in another GUI terminal."
    fi
    sleep 0.25
done

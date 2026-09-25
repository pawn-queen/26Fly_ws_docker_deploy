#!/usr/bin/env bash

# Keep the lock file itself stable for the lifetime of the container.  Removing
# a locked file would allow another process to lock a new inode at the same
# path, defeating the single-instance guarantee.
acquire_26fly_task_lock() {
    local task_name=$1
    local lock_dir=/run/lock/26fly
    local lock_path

    case "${task_name}" in
        camera|detect|control) ;;
        *)
            echo "ERROR: unsupported 26Fly task lock: ${task_name}" >&2
            return 2
            ;;
    esac

    if ! command -v flock >/dev/null 2>&1; then
        echo "ERROR: flock is unavailable; refusing to start '${task_name}' without single-instance protection." >&2
        return 2
    fi

    mkdir -p -- "${lock_dir}"
    lock_path="${lock_dir}/${task_name}.lock"

    # This descriptor intentionally remains open across the caller's final
    # exec, so the kernel lock follows the real ROS/Python task and its children.
    exec {_26fly_task_lock_fd}>"${lock_path}"
    if ! flock -n "${_26fly_task_lock_fd}"; then
        echo "REFUSED: 26Fly task '${task_name}' is already running in this container." >&2
        return 3
    fi
}

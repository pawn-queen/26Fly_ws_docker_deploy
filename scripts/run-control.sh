#!/usr/bin/env bash
set -Eeuo pipefail

# An inherited ALLOW_FLIGHT_CONTROL value is not operator authorization.
# The one-shot value for the container is set only after this confirmation.
require_manual_confirmation() {
    local process_pgid terminal_pgid reply=

    if [[ ! -t 0 ]]; then
        echo "REFUSED: real flight control requires a foreground interactive terminal." >&2
        return 64
    fi

    process_pgid="$(ps -o pgid= -p "$$" 2>/dev/null)" || process_pgid=
    terminal_pgid="$(ps -o tpgid= -p "$$" 2>/dev/null)" || terminal_pgid=
    process_pgid="${process_pgid//[[:space:]]/}"
    terminal_pgid="${terminal_pgid//[[:space:]]/}"
    if [[ ! "${process_pgid}" =~ ^[1-9][0-9]*$ || "${process_pgid}" != "${terminal_pgid}" ]]; then
        echo "REFUSED: real flight control must be confirmed from the foreground terminal." >&2
        return 64
    fi

    trap 'exit 130' INT
    if ! printf '%s\n%s\n%s' \
        '警告：即将启动真实控制，可能发送 Offboard、Arm 和舵机命令。' \
        '请确认已完成必要的飞行前检查。' \
        '是否继续启动ROS节点? (y/n): ' > /dev/tty; then
        echo "REFUSED: the terminal is unavailable for operator confirmation." >&2
        return 64
    fi
    if ! IFS= read -r -n 1 reply < /dev/tty; then
        echo >&2
        echo "用户取消启动：未收到有效的终端确认。" >&2
        return 1
    fi
    echo >&2
    if [[ "${reply}" != y && "${reply}" != Y ]]; then
        echo "用户取消启动。" >&2
        return 1
    fi
    trap - INT
}

require_manual_confirmation

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/runtime.sh"
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/managed-task.sh"
load_runtime_settings
run_managed_control_unit "$@"

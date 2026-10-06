#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 || ! "$1" =~ ^[0-9]{1,2}$ || ! "$2" =~ ^[0-9]{1,2}$ ]]; then
    echo "用法: sudo $0 <日 1-31> <小时 0-23>（北京时间，固定 2026 年 10 月）" >&2
    exit 2
fi

day=$((10#$1))
hour=$((10#$2))
if (( day < 1 || day > 31 || hour > 23 )); then
    echo "错误：日必须为 1-31，小时必须为 0-23。" >&2
    exit 2
fi

if [[ "$(uname -s)" != Linux ]]; then
    echo "错误：请在 Jetson Linux 宿主机上运行此脚本。" >&2
    exit 2
fi
if [[ "$(id -u)" != 0 ]]; then
    echo "错误：修改系统时间需要 root 权限，请使用 sudo。" >&2
    exit 1
fi
for command_name in date timedatectl systemd-detect-virt; do
    command -v "${command_name}" >/dev/null || {
        echo "错误：缺少命令 ${command_name}。" >&2
        exit 2
    }
done
if systemd-detect-virt --container --quiet; then
    echo "错误：请在宿主机执行，不能在容器内修改时间。" >&2
    exit 2
fi

printf -v target_time '2026-10-%02d %02d:00:00 +0800' "${day}" "${hour}"
target_epoch="$(date --date="${target_time}" +%s)"

before_time="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %z')"
printf '修改前（北京时间）: %s\n' "${before_time}"
timedatectl set-ntp false
echo "NTP 已关闭；任务停止后可执行 sudo timedatectl set-ntp true 恢复。"
date --set="@${target_epoch}" >/dev/null
after_time="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S %z')"
printf '修改后（北京时间）: %s\n' "${after_time}"

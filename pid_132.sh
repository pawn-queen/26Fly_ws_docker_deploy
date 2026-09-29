#!/usr/bin/env bash
set -Eeuo pipefail

deploy_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

control_args=(
  --first-align-threshold 0.25 
  --first-align-time-window 2.0 
  --first-align-check-freq 5 
  --second-align-threshold 0.08 
  --second-align-time-window 2.0
  --second-align-check-freq 6 
  --first-align-maxtime 20.0 
  --second-align-maxtime 20.0 
  --drop-phase-timeout 80.0 
  --descent-height 0.7 
  --timer-period 0.05 
  --takeoff-height -1.7 
  --target-order 1 3 2 
  --search-height -4.5 
  --kp 0.9000 
  --ki 0.5000 
  --kd 0.000 
  --kf 0.15 
  --depthcam_xoffset -0.0565 
  --depthcam_yoffset 0.041 
  --widecam-xoffset 0.030 
  --widecam-zoffset 0.000 
  --align-maxstep 0.2 
  --forward-x 32.5 
  --recon-forward-distance 25 
  --record-video 
  --post-drop-delay 1.0 
  --recon-search-height -2.7 
  --enable_smooth_transit=true #默认关闭，开启后使用平滑移动方法前往侦查区
  --target-anchor-mode top25 #可选参数为top25，选择候选锚点前25%的中位数作为打击目标，max-confidence选择最高置信度。默认为max confidence
  --target-confidence-window 2 #选取最近n秒的目标加入锚点候选

)

exec "${deploy_dir}/scripts/run-control.sh" "${control_args[@]}" "$@"
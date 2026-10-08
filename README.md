# 26Fly Jetson 实机部署

本目录按 `初步方案.md` 实现为一个长期存在的 `26fly-runtime` 宠物容器。这里的 systemd 明确是**容器内 systemd**：镜像以 `/sbin/init` 作为 PID 1，负责初始化、监督和重启 Micro XRCE-DDS Agent 与 mavlink-routerd；Jetson 宿主 systemd 不安装本项目的服务单元，只负责正常启动 Docker Engine。

```text
Jetson Ubuntu 22.04 host
├── Jetson Linux/BSP、Kernel、NVIDIA Driver、JetPack、udev
├── Docker Engine
├── /home/<user>/uav/26Season_Fly_ws_jetson/src  (Git + VS Code)
└── docker start 26fly-runtime
        │
        ▼
26fly-runtime
├── PID 1: /sbin/init --unit=26fly.target
├── container systemd
│   ├── micro-xrce-agent.service   Restart=always
│   ├── mavlink-routerd.service    Restart=always
│   ├── systemd-journald.service   console logs by unit
│   └── camera/control             manually started units
├── ROS 2 Humble + rmw_fastrtps_cpp
├── CUDA/TensorRT/PyTorch/YOLO/OpenCV/RealSense userspace
└── /workspace
    ├── src       host read-only bind mount
    ├── build     Docker named volume
    ├── install   Docker named volume
    └── log       Docker named volume
```

## 设计边界

- 只有一个长期存在的 runtime 容器；不采用一节点一容器，也不使用 Compose 管理 ROS 节点。
- 日常生命周期是 `docker start`、`docker stop`、`docker exec`。同名容器存在时，创建脚本拒绝自动删除或 recreate。
- 容器按方案使用 root、`--privileged` 和 `/dev:/dev`，动态出现的 UART、USB、video、media 节点对既有容器立即可见。
- 源码只读挂载到 `/workspace/src`，宿主保存修改后容器立即可见。build/install 和应用文件日志写入 named volume；journald 写入容器可写层。
- systemd 自动启动并监督两个长期通信服务。RealSense、detect 和 control 由人工启动，运行期间也由容器内 systemd 托管。
- control 永不随容器或 Jetson 开机启动；任务退出不会停止容器、Agent 或 mavlink-router。
- Jetson BSP、内核模块、GPU 驱动和宿主 udev 不进入镜像。
- 禁止执行 `chmod -R 777 /dev`。

由于容器同时使用 systemd、privileged 和宿主 `/dev`，镜像启动的是最小 `26fly.target`，不会进入普通 `multi-user.target`。镜像还屏蔽了容器内 udev、内核模块加载、sysctl 和 `/dev` tmpfiles 单元，避免它们与宿主硬件管理发生冲突。容器使用独立 PID namespace 和 private cgroup namespace；`/run`、`/run/lock` 是 tmpfs。该模式仍不是安全隔离边界，只应用于受控 Jetson 和可信飞行网络。

## 1. 配置宿主路径与硬件

```bash
cd /home/<user>/uav/26Fly_ws_docker_deploy
./scripts/init-env.sh --force
```

初始化脚本按两个仓库位于同一 `uav` 目录的布局，自动把 `HOST_WS_SRC` 指向相邻的 `26Season_Fly_ws_jetson/src`，因此不依赖用户名。`.env` 保存镜像名、容器名、宿主路径、固定的 `px4_msgs` 来源和 volume 前缀；其中宿主路径和 volume 前缀在 `docker create` 时确定，`px4_msgs` 来源供初始化脚本使用。`config/runtime.env` 只读挂载到容器 `/etc/26fly`，每次服务或人工任务启动时重新读取，因此修改串口、topic、模型和 ROS domain 后不需要 recreate 容器。

Jetson TensorRT 模型由源码仓库同步，detect 与 control 分别从各自包的模型目录读取：

```text
26Season_Fly_ws_jetson/src/detect/models/26fly_jetson.engine  # detect
26Season_Fly_ws_jetson/src/fly/models/26fly_jetson.engine     # control
```

两个文件必须分别在源码仓库中提交并推送；`check-host.sh` 会拒绝源码仓库存在未提交/未推送内容，以及任一模型缺失、非 `.engine`、未被 Git 跟踪或与当前提交不一致。模型和代码 `git pull` 后，既有容器会立即看到只读 bind mount 的新内容；重启相应任务进程即可加载，不需要 recreate。

`px4_msgs` 不复制进主源码仓库历史，而是在其 `src` 下作为固定 tag 的独立 checkout 初始化：

```bash
./scripts/init-px4-msgs.sh
```

默认同时锁定官方 `v1.17.0` tag 和完整 commit `86d8239e962f6939e05c3737784f60c02fa884db`；初始化、构建和验证都会拒绝错误 remote、错误 commit 或包含本地改动/未跟踪文件的 checkout。飞控固件版本改变时必须同步修改 `.env` 中的 `PX4_MSGS_REF`、`config/runtime.env` 中的期望版本及完整 commit，并更换 `VOLUME_PREFIX`；工作树干净时重新运行初始化脚本会获取并切换到新固定版本。
如果旧工作目录里已有一个没有自身 `.git` 的 `src/px4_msgs` 普通拷贝，初始化脚本会拒绝覆盖；先人工保留式移到 `26Season_Fly_ws_jetson/src` 之外，避免 colcon 扫描到两个同名包，再执行脚本。目标 Jetson 上的全新 clone 不会遇到这一残留。

XRCE 与 MAVLink 必须使用不同的物理 FCU 链路。默认配置只选择稳定 udev 链接，不对枚举顺序可能变化的 `ttyACM0/1` 做自动回退：

```bash
XRCE_SERIAL_DEVICE=/dev/serial/by-id/usb-1a86_USB_Single_Serial_5A98038797-if00
XRCE_SERIAL_CANDIDATES=""
MAVLINK_SERIAL_DEVICE=/dev/serial/by-id/usb-CUAV_PX4_CUAV_X7Pro_0-if00
MAVLINK_SERIAL_CANDIDATES=""
```

以上默认假定 1a86 TTL 适配器连接的飞控 UART 运行 uXRCE-DDS，CUAV USB 直连运行 MAVLink；必须用飞控端 `UXRCE_DDS_CFG`、`MAV_*_CONFIG`、`SYS_USB_AUTO` 和对应波特率确认。若协议角色相反，应交换两组设备。现有 `/dev/serial/by-id` 已稳定时无需安装示例 udev 规则；任一路 by-id 缺失都会保持 fail-closed，不会误开另一个 `ttyACM`。若实际只有一个串口，不得让两个服务同时打开它；应把其中一个链路改成 UDP，或增加独立链路。

RealSense 由 USB 驱动按设备识别，配置只检查名称中包含 `RealSense`，不固定容易变化的 `video0–5`。广角相机使用稳定的 `/dev/v4l/by-id/usb-LRCP_imx577_LRCP_imx577_01.00.00-video-index0`；预检会解析它实际指向的 `/dev/videoN`，确认它是 `imx577` 分组的首个节点且能列出采集格式，控制程序也直接打开该 by-id 路径。仍须核对实际分辨率与控制源码中的标定内参一致。

检查 Jetson、Docker/NVIDIA runtime、cgroup v2、源码和硬件配置：

```bash
./scripts/check-host.sh
```

## 2. 首次 build、create 和 workspace 初始化

```bash
./scripts/init-px4-msgs.sh
./scripts/build-image.sh
./scripts/create-runtime.sh
./scripts/start-runtime.sh
./scripts/build-workspace.sh
./scripts/verify-runtime.sh
```

`verify-runtime.sh` 现在是实机就绪检查：要求两路串口 daemon 已打开指定设备、RealSense USB/video 分组存在、IMX577 首个 video 节点具备采集格式、workspace 已由当前固定的 `px4_msgs` 构建，并对 TensorRT engine 执行一次真实 dummy inference。因此应在所有设备接好后执行；它不再把缺设备或缺模型当作可忽略信息。

`create-runtime.sh` 创建：

- `26fly-runtime`，镜像入口为 `/sbin/init`，PID 1 是容器内 systemd；
- `--restart unless-stopped`、NVIDIA runtime、host network、host IPC；
- root、`--privileged`、`/dev:/dev`、`--cgroupns private`；
- `/run` 与 `/run/lock` tmpfs；
- 宿主存在 `/tmp/.X11-unix` 时，将整个目录只读挂载到容器，供显式 GUI 调试入口使用；
- `${VOLUME_PREFIX}-build`、`${VOLUME_PREFIX}-install`、`${VOLUME_PREFIX}-log`。

如宿主存在 `/run/udev`、`/tmp/argus_socket` 或 `/tmp/.X11-unix`，创建脚本会额外挂载它们；不存在时不会在宿主制造空路径。`DISPLAY` 和 Xauthority 不会固化到容器，只由 GUI 调试入口按当前登录会话临时传入。

只有 Dockerfile、apt/requirements、`container/` 启动与验证脚本、systemd unit 或底层 ABI 改变时才构建新镜像，并进行一次明确的容器迁移。本版本同时更新容器脚本并新增 `/home/pixel/flylogs` 持久化兼容链接，因此从旧镜像迁移时必须重新 build；源码、`.engine` 和 `config/runtime.env` 的日常变化不需要重建镜像。

`HOST_WS_SRC`、`VOLUME_PREFIX` 和 bind/named-volume 挂载都在 `docker create` 时确定。本次从 archive 切换到 `26Season_Fly_ws_jetson`，已有容器必须保留式迁移；仅修改 `.env` 或重新 build 镜像不会改变旧容器挂载。迁移期间先保留旧容器，再创建并验证新的；新容器测试通过后删除已改名的旧容器：

```bash
./scripts/build-image.sh
docker stop 26fly-runtime
docker rename 26fly-runtime 26fly-runtime-pre-jetson-workspace
./scripts/create-runtime.sh
./scripts/start-runtime.sh
./scripts/build-workspace.sh
./scripts/verify-runtime.sh
# 完成本次升级涉及的全部测试并确认通过后
docker rm 26fly-runtime-pre-jetson-workspace
```

新的 `VOLUME_PREFIX` 会创建一套干净的 build/install/log named volume，避免旧版 `px4_msgs` 生成物混入。确认新版稳定前不要删除备份容器；测试通过后必须删除备份容器，避免残留无用容器。`docker rm` 不会删除旧 named volume；旧 volume 是否清理应另行确认，不能随容器自动删除。

## 3. 操作容器内 systemd

容器启动时 systemd 自动启动两个基础通信服务。宿主包装脚本内部执行的是 `docker exec 26fly-runtime systemctl ...`：

```bash
./scripts/systemctl.sh status micro-xrce-agent mavlink-routerd
./scripts/systemctl.sh restart micro-xrce-agent mavlink-routerd
./scripts/logs.sh -u mavlink-routerd.service -n 200
./scripts/logs.sh -u micro-xrce-agent.service --since today -f
./scripts/logs.sh -u 26fly-camera.service -n 100
./scripts/logs.sh -u 26fly-control.service -n 100 # 仅查看 systemd 管理事件
```

也可以进入容器后直接操作：

```bash
./scripts/shell.sh
systemctl status micro-xrce-agent.service
systemctl status mavlink-routerd.service
```

这些 `systemctl` 和 `journalctl` 命令连接的是容器内 systemd 与 journald，而不是宿主服务。最小 target 启动 journald 和 journal flush；MAVLink、Agent、Depth cam 的 stdout/stderr 按 unit 存入 `/var/log/journal`。`scripts/logs.sh` 将参数原样交给容器内 `journalctl`，可使用 `-u`、`--since`、`-n`、`-f` 筛选。journal 设置 `SystemMaxUse=256M` 和 `SystemMaxFileSize=16M`；journald 仅清理已归档文件，活跃文件可能使实际占用短暂超过 256 MiB。journal 存在容器可写层：停止、启动同一容器后仍可查询，删除并重建容器后消失。Detect 仍写到 `docker logs`，可用 `docker logs 26fly-runtime` 查看。ROS 自己写入 `/workspace/log/ros` 的文件，以及控制任务的 CSV、照片、视频仍在各自原有路径。设备暂时不存在时，启动包装器等待 15 秒后失败；容器 systemd 根据 `Restart=always` 继续重试，并在下一次启动时重新检查实时 `/dev`。

Control 仍由 systemd 管理，但程序 stdout/stderr 直接合并写入 `/workspace/log/control/logs/control_<北京时间YYYYMMDD_HHMMSS_纳秒>_<owner-id>.log`，每次授权启动使用一个独立文件。启动时打印完整路径，终端从文件起始位置实时跟随；无法创建文件时不启动 control。日志保存在现有 `${VOLUME_PREFIX}-log` 卷中，沿用该卷重建容器也会保留。新文件不受 journald 配额管理，需自行管理历史文件；正文保留程序原始输出，不附加 `short-iso-precise` 的行前缀。`scripts/logs.sh -u 26fly-control.service` 仍能查看 Started/Stopped/Failed 等 systemd 管理事件，但不再用于查询程序打印日志。

```bash
docker exec 26fly-runtime ls -lt /workspace/log/control/logs
# 将下方路径替换为本次启动时打印的完整日志路径
CONTROL_LOG_FILE='/workspace/log/control/logs/实际日志文件名.log'
docker exec -it 26fly-runtime tail -n 100 -F -- "${CONTROL_LOG_FILE}"
```

Control 文件日志改动只涉及宿主包装器，下一次启动 control 即生效，无需重建镜像、重建或重启 runtime，也无需执行 `build-workspace.sh`。若升级的是镜像内 journald 配置等内容，切换已有容器仍需短暂停机并重建镜像和容器；容器可写层无法通过 `docker restart` 换成新镜像。先停止人工任务，再执行以下保留式迁移，沿用现有 build/install/log 卷。旧容器只在验证期间用于回退；新容器测试通过后必须删除：

```bash
./scripts/build-image.sh
docker stop 26fly-runtime
docker rename 26fly-runtime 26fly-runtime-pre-journald
./scripts/create-runtime.sh
./scripts/start-runtime.sh
./scripts/verify-runtime.sh
./scripts/logs.sh -u micro-xrce-agent.service -n 20
./scripts/logs.sh -u mavlink-routerd.service -n 20
# 完成本次升级涉及的全部测试并确认通过后
docker rm 26fly-runtime-pre-journald
```

上述命令只验证基础通信服务；相机日志需在人工启动后用 `-u 26fly-camera.service` 查询，Control 程序日志使用上面的文件查询方式。Control 仍需逐次授权。执行最后一条 `docker rm` 前，必须先完成本次升级涉及的全部测试并确认通过；删除后旧容器的 `docker logs` 历史不再保留，新容器的 journal 从创建时开始记录。

Micro XRCE-DDS Agent v2.4.2 在同一个镜像中以 `UAGENT_USE_SYSTEM_FASTDDS=ON` 构建，直接链接 ROS Humble 的 Fast DDS 2.6/Fast CDR，避免 Agent 引入另一套 DDS 动态库。mavlink-router 固定为 v4。

## 4. 日常开发和人工任务

宿主修改：

```text
/home/<user>/uav/26Season_Fly_ws_jetson/src/...
```

容器 `/workspace/src/...` 会立即看到相同内容。Python 包使用：

```bash
./scripts/build-workspace.sh
```

即 `colcon build --symlink-install`。普通 Python 函数修改通常只需重启任务；修改 `setup.py`、`package.xml`、入口点、消息接口、新增模块或 C/C++ 时需要重新 build workspace。

RealSense 和实机检测在不同终端人工运行：

```bash
./scripts/run-camera.sh
./scripts/run-detect.sh
```

检测入口固定为 `ros2 run detect detect`。控制包装器显式调用 `control.0821auto`，不依赖历史仿真入口。整个 `src` 是单一只读 bind mount；宿主 Git 更新会立即反映到容器。

以上两个入口是比赛用无界面路径，语义保持固定：相机只发布 ROS topic，detect 固定使用
`show_image=false`，不继承宿主 `DISPLAY`。比赛视觉任务仍通过这些入口启动。

### 一次启动相机、检测器和双窗口

在 Jetson 当前图形桌面或远程桌面的终端运行：

```bash
./run_detect.sh
```

此宿主入口并行运行 `./start_camera.sh` 和无参数的 `./scripts/run-vision-debug.sh`。
相机启动、RGB／对齐深度／内参就绪检查、检测器启动及超时继续由 `start_camera.sh` 负责；
窗口先显示等待，收到图像后显示画面。看到 `Camera and detector are running` 后，
可以在另一终端按原流程启动控制任务；该提示不代表已检测到有效目标。
广角图像仍来自控制程序，未启动控制时广角窗口保持等待。RealSense 窗口默认显示新鲜匹配的 YOLO 框，广角标注保持现有任务逻辑。

在任一窗口按 `q`、Esc 或点击关闭，只关闭两个显示窗口，相机和检测器继续运行，
`run_detect.sh` 留在前台。需要恢复显示时，在另一图形终端运行 `./scripts/run-vision-debug.sh`。
在 `run_detect.sh` 的终端按 Ctrl-C 会停止本次启动的相机、检测器和仍在运行的显示会话；
TERM／HUP 同样执行清理。后来单独重新打开的显示会话由其自己的终端管理。
相机包装器退出或显示包装器非零退出时，此入口清理本次剩余组件并报告退出状态。
已有相机、检测器或显示会话的冲突仍按原机制拒绝，不接管已有任务。
控制程序、通信服务和容器由原流程独立管理。

该入口仅接受无参数启动，使用与现有显示入口相同的 X11 环境；不要用 `sudo` 运行。
在当前双窗口版本已经部署的前提下，新增宿主入口无需重建镜像或工作区。

### 已有任务的 RealSense RGB 和广角图像显示

先按下方比赛流程启动 `./start_camera.sh` 和需要的控制任务，再从 Jetson 当前图形桌面或远程桌面的另一终端运行：

```bash
echo "$DISPLAY"
./scripts/run-vision-debug.sh
```

无参数入口只启动独立的 C++ viewer，允许 camera、detect 和 control 已在运行；不会启动、重启或停止这些任务，也不会再次打开广角设备。显示使用两个独立窗口：RealSense RGB 窗口和广角窗口。在任一窗口按 `q`、Esc、点击关闭，或在显示终端按 Ctrl-C，会关闭两个显示窗口，任务继续运行。重新执行上述命令即可恢复显示。

RealSense RGB 窗口订阅原始彩色图、CameraInfo、`/detect/debug/image` 和
`/target_observation`。只有标注图与原始彩色帧的时间戳、坐标帧和尺寸一致且标注图未过期时，
才显示检测框；否则显示原始 RGB 图像。detect 默认开启 `publish_debug_image=true`，仅在
`/detect/debug/image` 有订阅者时绘制并发布完整标注图，包含矩形框、类别名和置信度；
选中目标为绿色并带 `SELECTED`，其他目标为橙色。YOLO 无检测结果时发布无框图，以清除上一帧的框。
无订阅者时跳过标注图复制、绘制、打包和发布，YOLO 与三维目标输出继续运行。
标注图默认最高 30 Hz；每张标注保持原 RGB header 和完整分辨率，限流不增加 YOLO 推理。
RealSense viewer 使用共享图像并持有像素缓冲所有者，仅在图像、匹配结果或可见提示变化时
复制、叠加和重绘。需要 RGB／BGR 编码转换时仍执行正常转换；GUI 事件循环保持 30 Hz。
`show_image=false` 保持不变，纯 SSH 无订阅时不会打开窗口，也不执行标注图处理。
此默认值对所有使用默认参数的检测入口生效；节点启动时显式设置
`publish_debug_image=false` 可禁用标注发布。关闭并重新打开 viewer 后，按需发布自动停止和恢复。
`/target_observation` 仍只提供被选中目标的三维中心点和置信度；viewer 在匹配帧上投影
绿色中心标记，并显示 XYZ。viewer 不订阅或预览深度图；RealSense 仍发布对齐深度，detect 仍用它计算目标三维坐标，比赛启动流程的深度就绪检查也保留。

相机和检测入口从 `config/runtime.env` 读取以下配置：

| 配置 | 默认值 | 行为 |
|---|---:|---|
| `REALSENSE_TARGET_FPS` | 60 | RGB／原生深度请求帧率；正整数可配置更高，0 沿用原配置 |
| `DETECT_MAX_PROCESSING_HZ` | 60 | 单模型推理的最高处理频率，不重复旧帧凑频率 |
| `DETECT_DEBUG_IMAGE_HZ` | 30 | 有订阅者时完整标注图的最高频率 |
| `DETECT_RECORD_FPS` | 15 | RGB 录像的采样及编码帧率，保持原分辨率 |

相机在取得现有单实例锁后，使用与 ROS 驱动同一套 librealsense SDK 查询原生 RGB／深度
默认尺寸、格式和共同支持档位，不启动、重置设备或修改曝光。启动参数识别和能力查询共用
最多 3 秒的截止时间；按请求档位、不高于请求值的 60、30 去重回退，保持原生尺寸和实际
启动默认格式。优化配置绑定同一设备并保留深度对齐、启用驱动帧同步；它不代表曝光硬件同步。
显式设备／profile 参数优先。无法可靠确认、旧驱动不能绑定格式、多设备不明确或查询失败时，
记录原因并沿用原启动配置；日志中的请求／支持档位不代表实测帧率。飞行中不切换相机档位。

检测同步回调只保存最新完整 RGB／对齐深度帧对及原时间戳、接收时刻和内参，单个推理线程
处理一对图像时，新的待处理对替换旧待处理对，不积压或混用不同帧。目标观测先于辅助绘图发布，
目标筛选、深度取样和坐标计算保持原样。录像由独立线程处理，只有一个待写 RGB 帧；按 15 FPS
采样而非每次推理都写入，编码落后时跳过旧帧，不复制旧图像补帧。逐目标 INFO 日志最多每两秒
输出一次。退出先停止接收并等待当前推理／写入结束，再销毁节点；受管理服务保留原有退出超时。

保守模式将 `REALSENSE_TARGET_FPS` 和 `DETECT_MAX_PROCESSING_HZ` 同时设为 30，再停止并重新
启动相机／检测器。配置允许更高目标，但必须在起飞前验证原分辨率支持及并发负载，不能保证 60 FPS。

广角窗口订阅 control 发布的 `/control/widecam/image_raw` 和 `/control/widecam/debug_image`，
图像发布目标在 `TARGETING_CYCLE=3`／`TIMEOUT_DROP=8` 为 10 Hz，其余状态为 30 Hz；
仅在有订阅者时打包并发布新帧。debug 是完整图像，保持现有
`GLOBAL_SEARCH`、`RECON_SEARCH` 阶段的识别框；其他状态发布原图，不扩大识别阶段。
控制程序加载模型并完成首次 `track()` 预热前暂停广角图像发布，窗口显示等待；模型就绪后，
下一个发布周期按当前阶段恢复预览。无订阅者或未预热完成时，发布定时器以 10 Hz 检查；
周期只在变化时更新并重置，不重建定时器。
viewer 按源时间戳、frame_id 和尺寸关联两路图像，最多缓存 8 组源帧，从每组首次接收
开始缓冲约 100 毫秒。每轮显示已到期的最新源帧，有对应 debug 时显示完整标注图，
否则显示 raw；不把旧框叠加到新原图，也不等待积压的旧推理结果。debug 单独到达时也能显示。
晚到的更旧帧被丢弃，同一源帧的新 debug 可更新当前画面，包括阶段清框。
缓冲时间不含采集、推理、传输和调度耗时；阶段清框也可能经过缓冲，不承诺严格时限。
未收到有效图像时显示等待；超过 1 秒没有新鲜图像时显示 `STALE`。断流恢复后重新显示新帧。
GUI 事件循环保持 30 Hz，但只有图像或提示改变时重绘广角窗口。

`pid_132.sh` 显式设置 `--camera-timer-period 0.03333333333333333` 和
`--vision-timer-period 0.03333333333333333`，广角采集及搜索推理目标均为 30 Hz；
`--timer-period 0.05` 继续决定控制、PID 时间步长和 Offboard 心跳，执行器保持五线程。
新采集参数未设置时仍沿用控制周期，其他入口的视觉处理默认周期仍为 0.1 秒。
视觉定时器在 `GLOBAL_SEARCH`／`RECON_SEARCH` 保持配置频率；模型就绪后的非搜索阶段使用
`max(0.1, vision_processing_period)`。无头非搜索回调仍维护重置请求，但不读取、复制或叠字图像；
当前非搜索阶段原本就不执行 YOLO、录像或拍照。首次模型加载保持原触发周期，旧推理结束后的
重置及视觉代次检查继续保留；断流、无效位姿和重置失败不会吞掉维护请求。
两个视觉定时器只在各自互斥回调的 `finally` 中调整，控制不等待模型。搜索入口、重置或重新
打开预览可能等待一个约 100 毫秒的维护周期，阶段清框仍不承诺严格时限。无头主线程每 0.05 秒
检查退出，本地 GUI 保留事件循环并按维护频率更新非搜索图像。
显式设置采集周期时会请求对应摄像头 FPS 并记录协商结果，不改分辨率、像素格式或标定。
30 Hz 是调度目标，实际新图像帧率取决于相机能力、YOLO 耗时和设备负载；帧序号去重避免
重复推理。保持默认 30 帧跟踪历史，满速时覆盖时间约一秒，目标筛选、建图和搜索超时不变。
录像开关与内容保持原样，推理提速也可能提高录像编码和写入负载。`pid_132.sh` 沿用现有
`.gitignore` 规则，此次不改变 Git 索引；已追踪的版本仍会包含改动，未追踪的部署副本需单独同步。

控制定时器优化可以先单独同步 Python 源码并重启控制任务，无需重建镜像或工作区。完整方案
包含镜像内相机／检测入口、能力查询工具和 C++ viewer，需要按上方保留式流程重建镜像、
迁移容器并重启相机、检测器和控制；仅更新 Python 源码或 `docker restart` 不会升级镜像组件。
此次没有新增 ROS 包模块或消息接口，既有 `--symlink-install` 的 Python 包无需重新构建；
全新容器仍按原流程初始化工作区。完成首次部署后，仅修改帧率配置再重启相机／检测器即可，
无需再次重建镜像。
沿用现有源码挂载和 build/install/log 卷。实机验收应分别统计采集、推理、发布及窗口显示的新
源帧频率，并比较开启显示前后的 CPU、内存、录像负载与控制心跳，不能用 GUI 重绘次数代替帧率。
先验证定时器优化，再测广角搜索 30 Hz 与 RealSense 的并发负载。稳定目标场景下，处理频率
验收目标为配置值的 90% 以上，图像到目标发布 P95 延迟不超过 100 毫秒；控制／心跳 P99 间隔
较基线增加不超过 10 毫秒，无新增超过 0.20 秒的间隔、通信异常或持续积压。不满足时在起飞前
使用 30 Hz 保守模式重新验证，不在飞行中重启相机。

调试入口仅接受本地形式的 X11 display（例如 `:1002`），每次动态读取当前 `$DISPLAY`，不会将
会话编号写入容器配置。脚本用当前图形用户的 Xauthority cookie 创建容器内临时授权文件，
不会执行 `xhost +`；因此不要用 `sudo` 启动它。同一时间只允许一个图像显示会话。

需要原先的独立 RealSense/detect 调试栈时，显式运行：

```bash
./scripts/run-vision-debug.sh --standalone
```

`--standalone` 会拒绝已有的 camera、detect 或 control，依次启动 RealSense、无界面 detect 和 viewer；为本次 detect 设置 `publish_debug_image=true`，保持 `show_image=false`。此模式只显示 RealSense RGB，不预览深度图或广角相机；启动 detect 前仍等待 RGB、对齐深度和内参样本。退出会停止本会话启动的 camera、detect 和 viewer。

首次升级这两个窗口和新的启动脚本时，先停止人工任务，再构建镜像并保留式迁移容器；viewer 和容器启动脚本属于镜像内容，单纯 `docker restart` 不会加载它们的新版，也不能给旧容器增加 X11 mount：

```bash
./scripts/build-image.sh
docker stop 26fly-runtime
docker rename 26fly-runtime 26fly-runtime-pre-wide-viewer
./scripts/create-runtime.sh
./scripts/start-runtime.sh
./scripts/build-workspace.sh
./scripts/verify-runtime.sh
# 确认比赛任务、已有任务显示和 standalone 调试均通过后
docker rm 26fly-runtime-pre-wide-viewer
```

本次变化不改变 workspace ABI，可继续使用 `.env` 中现有的 build/install/log named volumes。
广角图像发布来自相邻源码仓库 `26Season_Fly_ws_jetson/src/fly/control/0821auto.py`，通过 `/workspace/src` 只读挂载和 Python symlink install 加载。首次升级执行 `build-workspace.sh` 刷新 install volume，并在之后重新启动控制任务；已运行的旧控制进程不会自动加载新源码。后续普通 Python 函数修改通常只需重启相应任务，C++ viewer 或 `container/` 脚本修改仍需重建镜像和迁移容器。确认三条路径均正常前，保留改名后的旧容器以便回退；验证通过后再删除旧容器。

系统时间回到 1970 年且 NTP 同步失败时，先在 **Jetson 宿主机**上手动校时，再启动相机、检测，最后运行 `pid_132.sh`。已运行的相机、检测和控制任务应先停止，避免运行中发生时间跳变。本次十月交付的校时脚本固定使用 **2026 年 10 月、北京时间（+08:00）**，输入日和小时，分钟、秒均为 `00`，支持 `06 09` 等前导零输入：

```bash
# 示例：设置为北京时间 2026-10-06 15:00:00；请按现场时间修改 6 和 15
sudo ./scripts/set-host-time.sh 6 15
```

脚本校验参数后关闭 NTP 并修改宿主系统时间，打印修改前后时间，不改变系统时区；容器同时看到新的系统时间。仅新增宿主脚本，无需重建镜像或 ROS 工作空间。任一步失败即退出；如果关闭 NTP 后设置时间失败，NTP 仍保持关闭。需要恢复网络校时时，在任务停止后执行 `sudo timedatectl set-ntp true`。这是粗略校时，现有日志仍按日期过滤，同一小时内较晚的历史日志仍可能被回放。

启动控制前，应先在另一终端运行 `./start_camera.sh`，或需要同时显示时运行 `./run_detect.sh`，等待相机和检测器已运行的提示。`start_camera.sh` 先启动 camera，等待彩色图、对齐深度图及相机内参的样本，再启动 detect 并等待 `/target_observation` 的 publisher。当前 `pid_*.sh` 本身不重复执行这些视觉话题预检；有 publisher 也不等于已产生有效检测结果。

真实控制必须由操作员在前台终端逐次确认，以下命令任选其一：

```bash
./pid_132.sh
./pid_231.sh
./pid_213.sh
```

脚本会先警告真实控制可能发送 Offboard、Arm 和舵机命令，并询问“是否继续启动ROS节点? (y/n): ”。
仅输入 `y` 或 `Y` 才继续；其他输入、输入结束、非前台交互终端及提示期间 Ctrl-C 都不会启动控制。
即使预先设置 `ALLOW_FLIGHT_CONTROL=YES`，也不能跳过询问。

确认后，宿主脚本留在前台跟踪本次 control 日志文件及 `26fly-control.service` 状态，Ctrl-C 仍通过 systemd 停止本次 control；
通信服务和容器继续运行。宿主使用 `systemd-run --setenv` 仅为本次 transient unit 设置内部许可，
容器入口再次核对；`config/runtime.env` 永久保持 `ALLOW_FLIGHT_CONTROL=NO`。此确认用于防止误启动，
不代替 PX4 飞行前检查。

停止和恢复整个运行环境：

```bash
./scripts/stop-runtime.sh
./scripts/start-runtime.sh
```

`docker stop` 向 PID 1 发送 systemd 的退出信号，systemd 先停止服务再退出。容器和三个 named volume 均保留。

## 5. 当前实机阻断项

部署层不会修改 Git 管理的飞控源码。当前仍需处理：

1. detect/control 的 `26fly_jetson.engine` 当前必须分别放入各自的 `src/detect/models`、`src/fly/models` 并提交；任一缺失时预检都会失败。
2. 控制入口会检查 PX4 topic/sample、RealSense 三条输入流和 `yolov5_ros2` publisher；`vehicle_command_ack` 的实际命令结果和三条 `/fmu/in/*` reader 身份仍必须在拆桨台架上验证。
3. `detect/package.xml` 含无效 `test_interface`，`fly/package.xml` 错列 Python 标准库；因此依赖暂以审查过的 apt/pip 清单为主。
4. 控制程序会在人工授权启动后自动请求 Offboard、解锁和起飞；回调异常处理、舵机数值/方向以及相机内外参必须在上桨前完成 fail-safe 与台架验证。
5. 广角相机使用 by-id 路径，检查脚本和控制程序会将其解析到实际 `/dev/videoN` 后确认 `imx577` 分组的首个节点；相机重新枚举时允许 `/dev/videoN` 改变，但 by-id 链接必须重新出现且仍指向正确的 `video-index0`。

以上问题不会被容器或 systemd 掩盖，控制入口保持 fail-closed。

## 6. 资源和版本

Orin Nano 8 GB 默认采用顺序 colcon executor、两个原生编译 job、headless 和关闭录像。运行配置只接受目标 Orin Nano 对应的 TensorRT `.engine`；它应在相同 JetPack/CUDA/TensorRT 环境中生成并经过加载验证。

基础镜像 tag、Agent v2.4.2、mavlink-router v4 和 Python wheel 已固定。Ubuntu/ROS apt 仓库仍会滚动更新；若需要字节级复现，应继续固定基础镜像 digest 并使用经过验证的 apt snapshot。切换 JetPack、ROS/Python ABI、PX4 消息版本或大型分支时应更换 `VOLUME_PREFIX`。

参考：

- [systemd Container Interface](https://systemd.io/CONTAINER_INTERFACE/)
- [Docker container run reference](https://docs.docker.com/reference/cli/docker/container/run/)
- [PX4 uXRCE-DDS version selection](https://docs.px4.io/main/en/middleware/uxrce_dds#version-selection)
- [px4_msgs v1.17.0 release](https://github.com/PX4/px4_msgs/releases/tag/v1.17.0)
- [mavlink-router](https://github.com/mavlink-router/mavlink-router)

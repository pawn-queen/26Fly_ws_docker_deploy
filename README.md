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
./scripts/logs.sh -u 26fly-control.service -n 100
```

也可以进入容器后直接操作：

```bash
./scripts/shell.sh
systemctl status micro-xrce-agent.service
systemctl status mavlink-routerd.service
```

这些 `systemctl` 和 `journalctl` 命令连接的是容器内 systemd 与 journald，而不是宿主服务。最小 target 启动 journald 和 journal flush；MAVLink、Agent、Depth cam、Control 的 stdout/stderr 按 unit 存入 `/var/log/journal`。`scripts/logs.sh` 将参数原样交给容器内 `journalctl`，可使用 `-u`、`--since`、`-n`、`-f` 筛选。journal 设置 `SystemMaxUse=256M` 和 `SystemMaxFileSize=16M`；journald 仅清理已归档文件，活跃文件可能使实际占用短暂超过 256 MiB。journal 存在容器可写层：停止、启动同一容器后仍可查询，删除并重建容器后消失。Detect 仍写到 `docker logs`，可用 `docker logs 26fly-runtime` 查看。ROS 自己写入 `/workspace/log/ros` 的文件，以及控制任务的 CSV、照片、视频仍在各自原有路径。设备暂时不存在时，启动包装器等待 15 秒后失败；容器 systemd 根据 `Restart=always` 继续重试，并在下一次启动时重新检查实时 `/dev`。

切换已有容器需要短暂停机并重建镜像和容器；容器可写层无法通过 `docker restart` 换成新镜像。先停止人工任务，再执行以下保留式迁移，沿用现有 build/install/log 卷。旧容器只在验证期间用于回退；新容器测试通过后必须删除：

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

上述命令只验证基础通信服务；相机和 Control 的日志需在人工启动对应任务后分别用 `-u 26fly-camera.service`、`-u 26fly-control.service` 查询。Control 仍需逐次授权。执行最后一条 `docker rm` 前，必须先完成本次升级涉及的全部测试并确认通过；删除后旧容器的 `docker logs` 历史不再保留，新容器的 journal 从创建时开始记录。

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

### 已有任务的 RealSense 和广角图像显示

先按下方比赛流程启动 `./start_camera.sh` 和需要的控制任务，再从 Jetson 当前图形桌面或远程桌面的另一终端运行：

```bash
echo "$DISPLAY"
./scripts/run-vision-debug.sh
```

无参数入口只启动独立的 C++ viewer，允许 camera、detect 和 control 已在运行；不会启动、重启或停止这些任务，也不会再次打开广角设备。显示使用两个独立窗口：RealSense RGB/深度和任务广角图像。在任一窗口按 `q`、Esc、点击关闭，或在显示终端按 Ctrl-C，会关闭两个显示窗口，任务继续运行。重新执行上述命令即可恢复显示。

RealSense 窗口订阅原始彩色图、对齐深度、CameraInfo、`/detect/debug/image` 和
`/target_observation`。只有标注图与原始彩色帧的时间戳、坐标帧和尺寸一致且标注图未过期时，
才显示检测框；否则显示原始 RGB 图像。比赛 detect 默认不发布标注图时，viewer 使用原始 RGB，不为打开显示而重启 detect。
`/target_observation` 仍只提供被选中目标的三维中心点和置信度；viewer 在匹配帧上投影
绿色中心标记，并显示 XYZ 与对齐深度。

广角窗口订阅 control 发布的 `/control/widecam/image_raw`（最高 10 Hz）和 `/control/widecam/debug_image`。debug 是完整图像，保持现有 `GLOBAL_SEARCH`、`RECON_SEARCH` 阶段的识别框；其他状态发布原图，不扩大识别阶段。viewer 优先显示新鲜 debug，debug 缺失或过期时使用新鲜 raw，不要求两路图像时间戳相同。未收到有效图像时显示等待；超过 1 秒没有新鲜图像时显示 `STALE`，避免将冻结的画面误认为实时图像。任务关闭相机或停止图像发布后，窗口会进入等待或失效状态。

调试入口仅接受本地形式的 X11 display（例如 `:1002`），每次动态读取当前 `$DISPLAY`，不会将
会话编号写入容器配置。脚本用当前图形用户的 Xauthority cookie 创建容器内临时授权文件，
不会执行 `xhost +`；因此不要用 `sudo` 启动它。同一时间只允许一个图像显示会话。

需要原先的独立 RealSense/detect 调试栈时，显式运行：

```bash
./scripts/run-vision-debug.sh --standalone
```

`--standalone` 会拒绝已有的 camera、detect 或 control，依次启动 RealSense、无界面 detect 和 viewer；为本次 detect 设置 `publish_debug_image=true`，保持 `show_image=false`。此模式只显示 RealSense，不启动或预览广角相机。退出会停止本会话启动的 camera、detect 和 viewer。

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

启动控制前，应先在另一终端运行 `./start_camera.sh`：它先启动 camera，等待彩色图、对齐深度图及相机内参的样本，再启动 detect 并等待 `/target_observation` 的 publisher。当前 `pid_*.sh` 本身不重复执行这些视觉话题预检；有 publisher 也不等于已产生有效检测结果。

真实控制必须由操作员在前台终端逐次确认，以下命令任选其一：

```bash
./pid_132.sh
./pid_231.sh
./pid_213.sh
```

脚本会先警告真实控制可能发送 Offboard、Arm 和舵机命令，并询问“是否继续启动ROS节点? (y/n): ”。
仅输入 `y` 或 `Y` 才继续；其他输入、输入结束、非前台交互终端及提示期间 Ctrl-C 都不会启动控制。
即使预先设置 `ALLOW_FLIGHT_CONTROL=YES`，也不能跳过询问。

确认后，宿主脚本留在前台跟踪 `26fly-control.service`，Ctrl-C 仍通过 systemd 停止本次 control；
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

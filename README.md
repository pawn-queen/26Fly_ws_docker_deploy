# 26Fly Jetson 实机部署

本目录按 `初步方案.md` 实现为一个长期存在的 `26fly-runtime` 宠物容器。这里的 systemd 明确是**容器内 systemd**：镜像以 `/sbin/init` 作为 PID 1，负责初始化、监督和重启 Micro XRCE-DDS Agent 与 mavlink-routerd；Jetson 宿主 systemd 不安装本项目的服务单元，只负责正常启动 Docker Engine。

```text
Jetson Ubuntu 22.04 host
├── Jetson Linux/BSP、Kernel、NVIDIA Driver、JetPack、udev
├── Docker Engine
├── /home/queen/uav/26Season_Fly_ws_archive/src  (Git + VS Code)
└── docker start 26fly-runtime
        │
        ▼
26fly-runtime
├── PID 1: /sbin/init --unit=26fly.target
├── container systemd
│   ├── micro-xrce-agent.service   Restart=always
│   └── mavlink-routerd.service    Restart=always
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
- 源码只读挂载到 `/workspace/src`，宿主保存修改后容器立即可见。root 产生的 build/install/log 只写入 named volume。
- systemd 只负责两个长期通信服务。RealSense、detect 和 control 是人工启动的任务进程，不属于 systemd。
- control 永不随容器或 Jetson 开机启动；任务退出不会停止容器、Agent 或 mavlink-router。
- Jetson BSP、内核模块、GPU 驱动和宿主 udev 不进入镜像。
- 禁止执行 `chmod -R 777 /dev`。

由于容器同时使用 systemd、privileged 和宿主 `/dev`，镜像启动的是最小 `26fly.target`，不会进入普通 `multi-user.target`。镜像还屏蔽了容器内 udev、内核模块加载、sysctl 和 `/dev` tmpfiles 单元，避免它们与宿主硬件管理发生冲突。容器使用独立 PID namespace 和 private cgroup namespace；`/run`、`/run/lock` 是 tmpfs。该模式仍不是安全隔离边界，只应用于受控 Jetson 和可信飞行网络。

## 1. 配置宿主路径与硬件

```bash
cd /home/queen/uav/26Fly_ws_docker_deploy
./scripts/init-env.sh --force
```

`.env` 只保存镜像名、容器名、宿主路径和 volume 前缀，这些值参与 `docker create`。`config/runtime.env` 只读挂载到容器 `/etc/26fly`，每次服务或人工任务启动时重新读取，因此修改串口、topic、模型和 ROS domain 后不需要 recreate 容器。

XRCE 与 MAVLink 必须使用不同的物理 FCU 链路。默认配置优先选择稳定 udev 链接，并仅把历史设备号作为候选：

```bash
XRCE_SERIAL_DEVICE=/dev/px4_xrce
XRCE_SERIAL_CANDIDATES="/dev/ttyACM1"
MAVLINK_SERIAL_DEVICE=/dev/px4_mavlink
MAVLINK_SERIAL_CANDIDATES="/dev/ttyACM0"
```

根据 `config/udev/99-px4.rules.example` 在宿主建立两个稳定链接。若实际只有一个串口，不得让两个服务同时打开它；应把其中一个链路改成 UDP，或增加独立 UART/USB 链路。不要用宽泛的 `/dev/tty*` 自动打开未知设备。

检查 Jetson、Docker/NVIDIA runtime、cgroup v2、源码和硬件配置：

```bash
./scripts/check-host.sh
```

## 2. 首次 build、create 和 workspace 初始化

```bash
./scripts/build-image.sh
./scripts/create-runtime.sh
./scripts/start-runtime.sh
./scripts/build-workspace.sh
./scripts/verify-runtime.sh
```

`create-runtime.sh` 创建：

- `26fly-runtime`，镜像入口为 `/sbin/init`，PID 1 是容器内 systemd；
- `--restart unless-stopped`、NVIDIA runtime、host network、host IPC；
- root、`--privileged`、`/dev:/dev`、`--cgroupns private`；
- `/run` 与 `/run/lock` tmpfs；
- `${VOLUME_PREFIX}-build`、`${VOLUME_PREFIX}-install`、`${VOLUME_PREFIX}-log`。

如宿主存在 `/run/udev` 或 `/tmp/argus_socket`，创建脚本会额外挂载它们；不存在时不会在宿主制造空路径。

只有 Dockerfile、apt/requirements、systemd unit 或底层 ABI 改变时才构建新镜像，并进行一次明确的容器迁移。源码和 `config/runtime.env` 的日常变化不需要重建镜像。

如果目标 Jetson 已经用错误的旧入口创建过同名容器，仅重新 build 镜像不会改变既有容器的 PID 1。先保留式迁移旧容器，再创建新的：

```bash
docker stop 26fly-runtime
docker rename 26fly-runtime 26fly-runtime-pre-pid1-systemd
./scripts/create-runtime.sh
./scripts/start-runtime.sh
```

三个 named volume 会继续复用；确认新版稳定前不要删除备份容器。

## 3. 操作容器内 systemd

容器启动时 systemd 自动启动两个基础通信服务。宿主包装脚本内部执行的是 `docker exec 26fly-runtime systemctl ...`：

```bash
./scripts/systemctl.sh status micro-xrce-agent mavlink-routerd
./scripts/systemctl.sh restart micro-xrce-agent mavlink-routerd
./scripts/logs.sh --tail 200 -f
```

也可以进入容器后直接操作：

```bash
./scripts/shell.sh
systemctl status micro-xrce-agent
systemctl status mavlink-routerd
```

这两条 `systemctl` 命令连接的是容器 PID 1，而不是宿主 systemd。最小 target 不启动 journald；两个服务继承 PID 1 的 stdout/stderr，由 `docker logs` 统一收集。设备暂时不存在时，启动包装器等待 15 秒后失败；容器 systemd 根据 `Restart=always` 继续重试，并在下一次启动时重新检查实时 `/dev`。

Micro XRCE-DDS Agent v2.4.2 在同一个镜像中以 `UAGENT_USE_SYSTEM_FASTDDS=ON` 构建，直接链接 ROS Humble 的 Fast DDS 2.6/Fast CDR，避免 Agent 引入另一套 DDS 动态库。mavlink-router 固定为 v4。

## 4. 日常开发和人工任务

宿主修改：

```text
/home/queen/uav/26Season_Fly_ws_archive/src/...
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

检测入口固定为 `ros2 run detect detect`，不会启动 `detect_ros_sim_lowHZ.py`。整个 `src` 是单一 bind mount，因此仿真源码仍然可见，但部署脚本不会调用它。

真实控制必须由操作员逐次授权：

```bash
ALLOW_FLIGHT_CONTROL=YES ./fly_A.sh
```

任务前台运行 `control/0821auto.py`；进程退出表示任务结束，systemd 管理的两个通信服务和容器继续运行。许可只传给本次 `docker exec`，`config/runtime.env` 永久保持 `ALLOW_FLIGHT_CONTROL=NO`。

停止和恢复整个运行环境：

```bash
./scripts/stop-runtime.sh
./scripts/start-runtime.sh
```

`docker stop` 向 PID 1 发送 systemd 的退出信号，systemd 先停止服务再退出。容器和三个 named volume 均保留。

## 5. 当前实机阻断项

部署层不会修改 Git 管理的飞控源码。当前仍需处理：

1. `fly/setup.py` 只有仿真入口，因此脚本暂时显式调用 `control.0821auto`。
2. `0821auto.py` 调用了当前不存在的 `ServoControl.publish_dual_actuator_command()`；控制脚本会在起飞前拒绝运行。
3. 当前 PX4 status subscription QoS 与历史实机代码不同，必须在拆桨台架上用实际 publisher QoS 验证。
4. `detect/package.xml` 含无效 `test_interface`，`fly/package.xml` 错列 Python 标准库；因此依赖暂以审查过的 apt/pip 清单为主。
5. 当前 `px4_msgs` 显示为 1.17.0，而开发中的固件树是 PX4 1.15.4；实飞前必须确认消息定义与固件构建来源一致。

以上问题不会被容器或 systemd 掩盖，控制入口保持 fail-closed。

## 6. 资源和版本

Orin Nano 8 GB 默认采用顺序 colcon executor、两个原生编译 job、headless 和关闭录像。`.pt` 可先用于功能验证；TensorRT `.engine` 应在目标 Orin Nano、当前 JetPack/CUDA/TensorRT 镜像中生成。

基础镜像 tag、Agent v2.4.2、mavlink-router v4 和 Python wheel 已固定。Ubuntu/ROS apt 仓库仍会滚动更新；若需要字节级复现，应继续固定基础镜像 digest 并使用经过验证的 apt snapshot。切换 JetPack、ROS/Python ABI、PX4 消息版本或大型分支时应更换 `VOLUME_PREFIX`。

参考：

- [systemd Container Interface](https://systemd.io/CONTAINER_INTERFACE/)
- [Docker container run reference](https://docs.docker.com/reference/cli/docker/container/run/)
- [PX4 uXRCE-DDS version selection](https://docs.px4.io/main/en/middleware/uxrce_dds#version-selection)
- [mavlink-router](https://github.com/mavlink-router/mavlink-router)

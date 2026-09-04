# 26Fly Jetson Docker 部署

这套文件把“低频变化的运行环境”和“高频变化的 ROS 2/Python 源码”分开：

```text
Jetson host
/home/queen/uav/26Season_Fly_ws_archive/src  (Git + VS Code)
                         │ read-only bind mount，修改即时可见
                         ▼
container /workspace/src
          /workspace/build    named volume
          /workspace/install  named volume
          /workspace/log      named volume
```

源码挂载为只读并不影响热更新：宿主上的修改仍立即出现在容器中，只是容器不能反向制造 root 所有者的源码文件。`colcon build --symlink-install` 后，已有 Python 模块内容的修改通常无需再次构建。修改 `setup.py`、`package.xml`、入口点、新增模块、C/C++ 或 ROS 消息时仍需重建 workspace。

## 设计边界

宿主保留 Jetson Linux/BSP、内核与固件、NVIDIA 驱动、NVIDIA Container Runtime、Docker、udev 规则、时间同步和必要的相机守护进程。镜像保存 ROS 2 Humble、编译工具、Python 科学计算依赖、RealSense 用户态包及 Jetson 版 PyTorch/Ultralytics/OpenCV。Dockerfile **没有**安装 BSP、内核驱动或 DKMS。

应用镜像固定为 `ultralytics/ultralytics:8.4.138-jetson-jetpack6`。它解决 Jetson ARM64 上 PyTorch/TensorRT 的组合；Dockerfile 不再安装通用 PyPI `torch`、`torchvision` 或 `ultralytics`。基础镜像上游目前允许较新的 `opencv-python-headless`，因此本项目会将它显式固定为 `4.11.0.86`，与 NumPy `1.24.3` 和 ROS Humble `cv_bridge` 一起做转换自检，避免 NumPy 2 ABI 混用。若要求字节级复现，应在验证后把 `BASE_IMAGE` 从 tag 改成仓库 digest，并使用固定 Ubuntu/ROS apt snapshot；仅靠 tag 和普通 apt 仓库无法保证未来每个 `.deb` 字节完全相同。

JetPack 6.2.3 的宿主是 L4T 36.5.2，而当前公开 Jetson 基础镜像仍可能基于 r36.4.x。它们属于同一 r36 系列，但这不是“精确同版”，所以下面的 CUDA、相机、GStreamer、TensorRT 检查必须在目标机完成，不能用本机 x86/WSL 的结果代替。

## 1. 宿主准备

建议刷写并固定 JetPack 6 生产版本，然后仅在宿主配置 Docker 与 NVIDIA runtime。按 NVIDIA 当前 Jetson 文档安装/配置后，至少确认：

```bash
docker compose version
docker info --format '{{json .Runtimes}}'
```

第二条输出必须包含 `nvidia`。若 runtime 尚未配置，典型流程是安装 NVIDIA Container Toolkit/Jetson 的 `nvidia-container` 包，然后执行：

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

不要把宿主 `/dev` 整体映射给容器，也不要使用 `privileged: true`。Compose 只给 RealSense USB 总线、指定广角相机和指定 PX4 串口。RealSense 的 cgroup 放行不能替代 Unix 文件权限：宿主还必须安装/验证官方 `librealsense2-udev-rules`（通常为 `99-realsense-libusb.rules`），并确认当前 UID 通过 `plugdev`/`video` 组可读写相机节点；只把规则装在容器里无效。

当前 `control` profile 只支持源码现有的“单个 V4L2 `/dev/videoN` + `cv2.VideoCapture`”路径。若 IMX577 实际依赖 Jetson CSI/Argus/GStreamer，还需先修改/验证采集代码，再按需最小化挂载 `/tmp/argus_socket`、对应 `/dev/media*` 等节点；本配置不会假装 V4L2 与 Argus 可以互换。

官方资料：

- [JetPack 6.2.3](https://developer.nvidia.com/embedded/jetpack-sdk-623)
- [Jetson Orin Nano 的 Docker 设置](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/setup_docker.html)
- [Ultralytics JetPack 6 Dockerfile](https://github.com/ultralytics/ultralytics/blob/main/docker/Dockerfile-jetson-jetpack6)
- [ROS 2 Humble 支持平台](https://docs.ros.org/en/humble/Releases/Release-Humble-Hawksbill.html)

## 2. 检查本机参数

目录已经带有适配当前路径的 `.env`。把目录复制到另一台 Jetson 后执行：

```bash
cd /home/queen/uav/26Fly_ws_docker_deploy
./scripts/init-env.sh --force
./scripts/check-host.sh
```

然后检查 `.env` 中的源码、模型、相机和串口路径。`WIDE_CAMERA_DEVICE` 目前应填写 `v4l2-ctl --list-devices` 显示的原始 `/dev/videoN`，因为现有 Python 代码仍按该路径查找。文件名中下划线不需要反斜杠；正确路径就是：

```text
/home/queen/uav/26Season_Fly_ws_archive/src
```

如 PX4 通过串口连接，推荐用 `config/udev/99-px4.rules.example` 在宿主建立 `/dev/px4_fcu`，再设置 `PX4_SERIAL_DEVICE=/dev/px4_fcu`。udev 规则属于宿主，而不是镜像。

## 3. 构建镜像和 workspace

首次操作：

```bash
cd /home/queen/uav/26Fly_ws_docker_deploy
docker compose build workspace
docker compose run --rm workspace build-workspace
docker compose run --rm workspace verify-runtime
```

Orin Nano 8 GB 默认使用顺序 colcon executor，单个 CMake 构建最多 2 个 job，避免编译与统一内存争用。当前实机节点只需要：

```text
px4_msgs detect control
```

`px4_ros_com` 没有被这两个节点 import，所以默认不构建。若确有需要，在 `.env` 的 `COLCON_PACKAGES` 后追加它并重新执行 `build-workspace`。

日常进入环境：

```bash
docker compose up -d workspace
docker compose exec workspace bash
```

在宿主 VS Code 中保存源码后，容器 `/workspace/src` 立刻变化。普通 Python 函数修改直接重启对应进程；涉及包元数据或生成代码时重新执行 `docker compose run --rm workspace build-workspace`。只有 Dockerfile、apt 清单或 requirements 变化才需要 `docker compose build`。

## 4. 实机服务

RealSense 与检测：

```bash
docker compose --profile camera --profile detect up realsense detect
```

默认检测入口是 `ros2 run detect detect`，明确不会调用仿真的 `detect_ros_sim_lowHZ.py`。

PX4 使用 UDP Agent：

```bash
docker compose --profile px4-udp up xrce-agent-udp
```

PX4 使用串口 Agent（当前历史配置为 `/dev/ttyACM1`、921600）：

```bash
docker compose --profile px4-serial up xrce-agent-serial
```

Agent 固定为 PX4/Humble 对应的 Micro XRCE-DDS Agent v2.4.2，并放在独立小镜像，避免它自带的 Fast DDS 库污染 ROS 应用镜像。v2.4.2 上游 CMake 曾指向现已不可解析的浮动分支 `2.12.x`，Dockerfile 会严格确认该行并改为不可变的 Fast-DDS tag `v2.12.2`；若上游源码布局变化则构建直接失败，不会静默使用别的版本。`ROS_DOMAIN_ID` 必须与 PX4 参数 `UXRCE_DDS_DOM_ID` 相等，默认均为 0。参考 [PX4 uXRCE-DDS 文档](https://docs.px4.io/main/en/middleware/uxrce_dds) 和 [eProsima Agent 源码构建文档](https://micro-xrce-dds.docs.eprosima.com/en/stable/installation.html)。

控制节点具备实际解锁/飞行/投放能力，因此默认双重拒绝启动。解决下一节的源码问题、拆桨台架验证后，再临时执行：

```bash
ALLOW_FLIGHT_CONTROL=YES docker compose --profile control up control
```

不要把 `ALLOW_FLIGHT_CONTROL=YES` 长期写进提交的配置。控制服务不会自动无限重启。启动脚本会校验两个 PX4 topic 的名称、消息类型，并实际等待一帧与控制代码相同 QoS 的数据；这仍然不能证明估计值正确、飞行模式正确或飞机安全。实飞前还要人工检查 `ros2 topic info -v`、消息数值、EKF/解锁状态、failsafe、急停和桨叶安全。

## 5. 当前源码已确认的问题

这些不是 Docker 问题，镜像也不应该悄悄篡改飞控源码：

1. `fly/setup.py` 只注册了仿真入口 `control.sim.0707:main`，没有真实控制入口。部署脚本因此明确运行 `/workspace/src/fly/control/0821auto.py`。
2. `0821auto.py` 调用了 8 次 `ServoControl.publish_dual_actuator_command()`，但当前 `ServoControl.py` 没有这个方法。`run-control` 会在起飞前拒绝启动，而不是等到投放阶段才崩溃。
3. 当前 `ServoControl` 对 PX4 status 使用 `RELIABLE` 订阅，历史实机代码使用 `BEST_EFFORT`；应按实际 `/fmu/out` publisher QoS 核对。
4. `detect/package.xml` 声明了不存在的 `test_interface`，并漏写部分真实依赖；`fly/package.xml` 把 Python 标准库 `math`、`time`、`collections` 错列成 ROS 依赖。因此首版镜像使用显式 apt/pip 清单，`check-rosdep` 暂时跳过这些无效 key。
5. `px4_msgs` 必须固定到与实际 PX4 固件兼容的 release/commit。当前源码版本是 1.17.0，刷机前要再次确认消息版本。

目前整个 `src` 按要求做单一 bind mount，所以 `control/sim/` 和 `detect_ros_sim_lowHZ.py` 仍会在容器文件系统中“可见”，而且 ament_python 仍可能安装它们；它们不会被实机 Compose 调用。在子目录放 `COLCON_IGNORE` 无法排除同一个 Python package 内的模块。若要求镜像中完全不可见，正确做法是以后把 real/sim 拆成独立 ROS package，而不是在部署层复制并修改开发源码。

## 6. 模型、日志与卷生命周期

`.pt` 可先验证功能，但 Orin 8 GB 实飞建议 batch=1、headless、默认关闭录像，并使用在目标 Jetson/目标 TensorRT 栈上生成的 FP16 `.engine`。参见 `models/README.md`。

查看 named volume：

```bash
docker volume ls | grep 26fly
docker compose exec workspace du -sh /workspace/build /workspace/install /workspace/log
```

切换 JetPack、ROS/Python ABI、PX4 消息版本或大型 Git 分支时，不要盲用旧 build/install。最安全的方式是先修改 `.env` 的 `VOLUME_PREFIX`，创建一套新卷。`docker compose down` 默认保留 named volume；`docker compose down -v` 会删除编译产物和日志，只能在确认无需保留后使用。

换到 UID/GID 不同的 Jetson 时同样应先运行 `init-env.sh --force`、重新 build 镜像，并换一个新的 `VOLUME_PREFIX`。已存在 named volume 的所有者不会因为修改 `.env` 自动变化，直接复用可能产生 `Permission denied`。

建议把 Docker data-root 和录像放在 NVMe。不要对应用容器设置激进的 `mem_limit`：Orin 的 CPU/GPU 共用 8 GB 内存，限制 batch、队列、录像和编译并行度更有效。

所有 ROS 服务使用 host network，DDS 发现和 UDP Agent 端口会进入宿主网络。飞行网络应视为受信网络，并在 Jetson 防火墙/交换网络上限制不需要的接口和来源；不要把 DDS/8888 直接暴露到公共或不可信 Wi-Fi。

## 7. rosdep 的使用边界

当前 package manifests 尚不可靠，所以镜像构建以 `apt-packages.txt` 和 `requirements.txt` 为准。修正 manifests 后可执行：

```bash
docker compose run --rm workspace rosdep update --rosdistro humble
docker compose run --rm workspace check-rosdep
```

不要直接对当前树无审查地运行 `rosdep install`。另外，当前打开的 `src/px4_msgs/.dockerignore` 对本方案没有作用：Docker build context 是本部署目录，源码通过运行时 bind mount 进入容器，从未 COPY 到镜像中。

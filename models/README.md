# 模型目录

该目录只读挂载到常驻容器的 `/workspace/models`，模型二进制由 `.gitignore` 排除。它保留为不经 Git 分发模型时的备用入口。

当前正式配置使用 Jetson 源码仓库中由 Git 同步的一份 TensorRT engine：

- `/workspace/src/detect/models/26fly_jetson.engine`

detect 与 control 默认复用该文件。切换为本目录中的独立模型时，修改 `config/runtime.env`：

```bash
DETECT_MODEL=/workspace/models/detect_fp16.engine
CONTROL_MODEL=/workspace/models/control_fp16.engine
```

两种模型目录都是只读 bind mount，宿主修改会即时反映到容器，下一次启动进程即读取新值，不需要重建镜像或重建容器。正式的 Git 同步方案还会由 `check-host.sh` 验证 engine 是否已被源码仓库跟踪。

TensorRT `.engine` 与 GPU 架构、TensorRT/CUDA/JetPack 版本强绑定。应在目标 Orin Nano 和当前 runtime 镜像中导出、验证；导出时先写到 `/workspace/log/exports`，再用 `docker cp` 复制到本目录，避免把源码或模型 bind mount 改为可写。

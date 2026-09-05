# 模型目录

该目录只读挂载到常驻容器的 `/workspace/models`，模型二进制由 `.gitignore` 排除。
当前 `config/runtime.env` 默认使用源码树中的两个 `.pt`：

- `/workspace/src/detect/models/26n_0807_bright_needle.pt`
- `/workspace/src/fly/models/26n_0807_bright_needle.pt`

切换到独立模型时，把模型放到宿主本目录，并修改 `config/runtime.env`：

```bash
DETECT_MODEL=/workspace/models/detect_fp16.engine
CONTROL_MODEL=/workspace/models/control_fp16.engine
```

配置目录是只读 bind mount，但宿主修改会即时反映到容器，下一次启动进程即读取新值，不需要重建镜像或重建容器。

TensorRT `.engine` 与 GPU 架构、TensorRT/CUDA/JetPack 版本强绑定。应在目标 Orin Nano 和当前 runtime 镜像中导出、验证；导出时先写到 `/workspace/log/exports`，再用 `docker cp` 复制到本目录，避免把源码或模型 bind mount 改为可写。

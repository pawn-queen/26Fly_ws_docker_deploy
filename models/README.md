# 模型目录

该目录会以只读方式挂载到容器 `/workspace/models`，模型二进制默认被 `.gitignore` 排除。

当前 `.env` 先使用源码树已有的：

- `/workspace/src/detect/models/26n_0807_bright_needle.pt`
- `/workspace/src/fly/models/26n_0807_bright_needle.pt`

若要使用 TensorRT，把文件放在宿主此目录，再修改 `.env`，例如：

```dotenv
DETECT_MODEL=/workspace/models/detect_fp16.engine
CONTROL_MODEL=/workspace/models/control_fp16.engine
```

`.engine` 与生成它的 GPU 架构、TensorRT/CUDA/JetPack 版本紧密耦合。应在目标 Orin Nano、目标镜像版本上导出并验证，不要把另一台机器或另一套 JetPack 的 engine 当作可移植文件。

如需从容器写入本目录做一次性导出，可显式覆盖只读挂载；导出结束后恢复默认只读方式：

```bash
docker compose run --rm \
  --volume "$PWD/models:/workspace/models:rw" \
  workspace \
  bash -lc 'cp /workspace/src/detect/models/26n_0807_bright_needle.pt /workspace/models/detect.pt && yolo export model=/workspace/models/detect.pt format=engine half=true batch=1 device=0'
```

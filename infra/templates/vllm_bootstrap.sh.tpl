#!/bin/bash
# =============================================================================
# 推理实例首次启动时由平台注入执行的初始化脚本
#   1. 校验 GPU 驱动
#   2. 挂载用于缓存模型权重的数据盘
#   3. 在独立虚拟环境中装配推理框架
#   4. 以 systemd 托管推理服务，进程异常自动拉起
# 全过程输出记录到日志文件，运维人员登录实例后可直接查看进度。
# =============================================================================
set -euo pipefail

MODEL_NAME="${model_name}"
MAX_MODEL_LEN=${max_model_len}
GPU_MEMORY_UTILIZATION="${gpu_memory_utilization}"
TENSOR_PARALLEL_SIZE=${tensor_parallel_size}
VLLM_VERSION="${vllm_version}"
VLLM_PORT=${vllm_port}
MODEL_SOURCE_BASE_URL="${model_source_base_url}"
PYTHON_PACKAGE_INDEX="${python_package_index}"
MODEL_CACHE_DIR="${model_cache_dir}"
DATA_DISK_MOUNT_POINT="${data_disk_mount_point}"
USE_DATA_DISK=%{ if use_data_disk }true%{ else }false%{ endif }
VIRTUAL_ENV_DIR=/opt/vllm-env
SERVICE_NAME=vllm

BOOTSTRAP_LOG="${bootstrap_log_path}"
exec > >(tee -a "$BOOTSTRAP_LOG") 2>&1

echo "=== 推理服务初始化开始 ==="

# 镜像首启阶段可能仍在执行自身的初始化任务，等锁释放后再动 apt
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "dpkg 锁被占用，等待 10 秒..."
  sleep 10
done

# -----------------------------------------------------------------------------
# GPU 驱动检查：公共镜像中只有预装驱动的镜像才能承载推理服务
# -----------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "未检测到 GPU 驱动，无法启动推理服务。"
  echo "请把 image_id 指向本区域预装 GPU 驱动的公共镜像（或把 image_name_regex 改成该镜像的锚定名称）后重新部署。"
  exit 1
fi
nvidia-smi

# -----------------------------------------------------------------------------
# 数据盘：格式化为可识别的文件系统并持久挂载，模型权重缓存在此
# -----------------------------------------------------------------------------
if [ "$USE_DATA_DISK" = "true" ]; then
  DATA_DISK=$(lsblk -dnpo NAME,TYPE | awk '$2=="disk"' | tail -n +2 | head -1)
  if [ -z "$DATA_DISK" ]; then
    echo "未找到可挂载的数据盘，模型权重将写入系统盘。"
  else
    if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
      echo "首次使用数据盘 $DATA_DISK，创建 ext4 文件系统..."
      mkfs.ext4 -q "$DATA_DISK"
    fi
    DISK_UUID=$(blkid -s UUID -o value "$DATA_DISK")
    mkdir -p "$DATA_DISK_MOUNT_POINT"
    if ! grep -q "$DISK_UUID" /etc/fstab; then
      echo "UUID=$DISK_UUID $DATA_DISK_MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    mount -a
    echo "数据盘 $DATA_DISK 已挂载到 $DATA_DISK_MOUNT_POINT"
  fi
fi

mkdir -p "$MODEL_CACHE_DIR"

# -----------------------------------------------------------------------------
# 依赖与推理框架
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends python3-pip python3-venv curl

python3 -m venv "$VIRTUAL_ENV_DIR"
"$VIRTUAL_ENV_DIR/bin/pip" install --upgrade pip --index-url "$PYTHON_PACKAGE_INDEX"
echo "安装 vllm==$VLLM_VERSION ..."
"$VIRTUAL_ENV_DIR/bin/pip" install --index-url "$PYTHON_PACKAGE_INDEX" "vllm==$VLLM_VERSION"

# -----------------------------------------------------------------------------
# systemd 托管：进程退出后自动拉起，实例重启后自动恢复服务
# -----------------------------------------------------------------------------
cat > /etc/systemd/system/$SERVICE_NAME.service <<UNIT
[Unit]
Description=vLLM OpenAI compatible inference service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HF_HOME=$MODEL_CACHE_DIR
Environment=HF_ENDPOINT=$MODEL_SOURCE_BASE_URL
Environment=HF_HUB_ENABLE_HF_TRANSFER=0
ExecStart=$VIRTUAL_ENV_DIR/bin/python -m vllm.entrypoints.openai.api_server --model $MODEL_NAME --host 0.0.0.0 --port $VLLM_PORT --tensor-parallel-size $TENSOR_PARALLEL_SIZE --max-model-len $MAX_MODEL_LEN --gpu-memory-utilization $GPU_MEMORY_UTILIZATION --enable-prefix-caching
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# -----------------------------------------------------------------------------
# 就绪等待：首次启动需要下载并加载权重，这里只做有界探测，超时不影响部署结果
# -----------------------------------------------------------------------------
echo "等待推理服务在端口 $VLLM_PORT 就绪（首次启动需下载模型权重，耗时较长）..."
READY=no
for attempt in $(seq 1 120); do
  if curl -fs "http://127.0.0.1:$VLLM_PORT/health" >/dev/null 2>&1; then
    READY=yes
    break
  fi
  sleep 10
done

if [ "$READY" = "yes" ]; then
  echo "推理服务已就绪，健康检查通过。"
else
  echo "推理服务在等待窗口内尚未就绪，可执行 systemctl status $SERVICE_NAME 与 journalctl -u $SERVICE_NAME 查看进度。"
fi

echo "=== 推理服务初始化完成 ==="

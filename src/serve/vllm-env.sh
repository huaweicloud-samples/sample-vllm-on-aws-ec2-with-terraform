#!/usr/bin/env bash
# =============================================================================
# 推理服务运行期管理的公共函数：参数取值优先级、服务配置读取与生成、健康探测
#   本文件由 src/serve/ 下的 vllm-start.sh / vllm-stop.sh / vllm-status.sh / vllm-logs.sh
#   引入，不单独执行。
#
# 参数名与 infra/variables.tf 的输入变量对应（同名，写成大写下划线形式）：
#   MODEL_NAME                   对应 var.model_name 与 output.model_name
#   MAX_MODEL_LEN                对应 var.max_model_len
#   GPU_MEMORY_UTILIZATION       对应 var.gpu_memory_utilization
#   TENSOR_PARALLEL_SIZE         对应 var.tensor_parallel_size
#   VLLM_PORT                    对应 var.vllm_port 与 output.inference_port
#   VLLM_VERSION                 对应 var.vllm_version
#   MODEL_SOURCE_BASE_URL        对应 var.model_source_base_url
#   PYTHON_PACKAGE_INDEX_URL     对应 var.python_package_index_url
#   MODEL_CACHE_DIR              对应 var.model_cache_dir
#   BOOTSTRAP_LOG_PATH           对应 var.bootstrap_log_path
#   DATA_DISK_MOUNT_POINT        对应 local.data_disk_mount_point（由 var.enable_data_disk 推导，无同名输入变量）
# 下面三项在 infra 侧没有同名输入变量，取值来源另行标注：
#   SERVICE_NAME                 取 output.service_name，实例初始化脚本按同一名字写 systemd 服务
#   VIRTUAL_ENV_DIR              实例初始化脚本内固定的运行环境目录，infra 侧不作为可调参数暴露
#   READY_TIMEOUT                仅本脚本使用（等待推理服务就绪的窗口），infra 侧无对应参数
#
# 每一项的取值优先级从高到低：
#   1. 命令行参数
#   2. 同名环境变量
#   3. 实例上已生效的服务配置（/etc/systemd/system/<SERVICE_NAME>.service 的 ExecStart 与 Environment）
#   4. 下面列出的默认值（与 infra/terraform.tfvars.example 的示例取值逐字相同）
# 只要不显式给出前三项，脚本读取到的就是部署时真正下发的取值，不会与 infra 侧漂移。
# =============================================================================

# -----------------------------------------------------------------------------
# 默认值：与 infra/variables.tf 的默认取值逐字对齐
# -----------------------------------------------------------------------------
SERVICE_NAME_DEFAULT="vllm"
VIRTUAL_ENV_DIR_DEFAULT="/opt/vllm-env"
DATA_DISK_MOUNT_POINT_DEFAULT="/mnt/models"
MODEL_NAME_DEFAULT="Qwen/Qwen2.5-0.5B-Instruct"
MODEL_CACHE_DIR_DEFAULT="/mnt/models/huggingface"
MODEL_SOURCE_BASE_URL_DEFAULT="https://huggingface.co"
PYTHON_PACKAGE_INDEX_URL_DEFAULT="https://pypi.tuna.tsinghua.edu.cn/simple"
VLLM_VERSION_DEFAULT="0.8.5"
VLLM_PORT_DEFAULT="8000"
MAX_MODEL_LEN_DEFAULT="8192"
GPU_MEMORY_UTILIZATION_DEFAULT="0.85"
TENSOR_PARALLEL_SIZE_DEFAULT="1"
BOOTSTRAP_LOG_PATH_DEFAULT="/var/log/vllm-setup.log"

# 就绪等待窗口（秒）：首次启动需要下载并加载模型权重，默认给到 10 分钟
READY_TIMEOUT_DEFAULT="600"

# -----------------------------------------------------------------------------
# 输出与退出码
# -----------------------------------------------------------------------------
# 1 参数不合法 / 2 缺少 systemd 或权限 / 3 服务未就绪 / 4 运行环境缺失
vllm_die() {
  printf '错误：%s\n' "$1" >&2
  exit "${2:-1}"
}

vllm_note() {
  printf '%s\n' "$*"
}

# -----------------------------------------------------------------------------
# 保存调用方已经给出的环境变量取值（在脚本改写这些变量之前执行一次）
# -----------------------------------------------------------------------------
vllm_capture_env() {
  SERVICE_NAME__ENV="${SERVICE_NAME:-}"
  VIRTUAL_ENV_DIR__ENV="${VIRTUAL_ENV_DIR:-}"
  DATA_DISK_MOUNT_POINT__ENV="${DATA_DISK_MOUNT_POINT:-}"
  MODEL_NAME__ENV="${MODEL_NAME:-}"
  MODEL_CACHE_DIR__ENV="${MODEL_CACHE_DIR:-}"
  MODEL_SOURCE_BASE_URL__ENV="${MODEL_SOURCE_BASE_URL:-}"
  PYTHON_PACKAGE_INDEX_URL__ENV="${PYTHON_PACKAGE_INDEX_URL:-}"
  VLLM_VERSION__ENV="${VLLM_VERSION:-}"
  VLLM_PORT__ENV="${VLLM_PORT:-}"
  MAX_MODEL_LEN__ENV="${MAX_MODEL_LEN:-}"
  GPU_MEMORY_UTILIZATION__ENV="${GPU_MEMORY_UTILIZATION:-}"
  TENSOR_PARALLEL_SIZE__ENV="${TENSOR_PARALLEL_SIZE:-}"
  BOOTSTRAP_LOG_PATH__ENV="${BOOTSTRAP_LOG_PATH:-}"

  CLI_SERVICE_NAME=""
  CLI_VIRTUAL_ENV_DIR=""
  CLI_DATA_DISK_MOUNT_POINT=""
  CLI_MODEL_NAME=""
  CLI_MODEL_CACHE_DIR=""
  CLI_MODEL_SOURCE_BASE_URL=""
  CLI_PYTHON_PACKAGE_INDEX_URL=""
  CLI_VLLM_VERSION=""
  CLI_VLLM_PORT=""
  CLI_MAX_MODEL_LEN=""
  CLI_GPU_MEMORY_UTILIZATION=""
  CLI_TENSOR_PARALLEL_SIZE=""
  CLI_BOOTSTRAP_LOG_PATH=""

  UNIT_SERVICE_NAME=""
  UNIT_VIRTUAL_ENV_DIR=""
  UNIT_DATA_DISK_MOUNT_POINT=""
  UNIT_MODEL_NAME=""
  UNIT_MODEL_CACHE_DIR=""
  UNIT_MODEL_SOURCE_BASE_URL=""
  UNIT_PYTHON_PACKAGE_INDEX_URL=""
  UNIT_VLLM_VERSION=""
  UNIT_VLLM_PORT=""
  UNIT_MAX_MODEL_LEN=""
  UNIT_GPU_MEMORY_UTILIZATION=""
  UNIT_TENSOR_PARALLEL_SIZE=""
  UNIT_BOOTSTRAP_LOG_PATH=""
}

# -----------------------------------------------------------------------------
# 取第一个非空值，并记录取值来源，供 status 输出可定位的排查信息
# -----------------------------------------------------------------------------
vllm_pick() {
  local name="$1" cli="$2" env_value="$3" unit_value="$4" fallback="$5"
  local chosen="$fallback" source="默认值"
  [ -n "$unit_value" ] && { chosen="$unit_value"; source="实例上的服务配置"; }
  [ -n "$env_value" ] && { chosen="$env_value"; source="环境变量"; }
  [ -n "$cli" ] && { chosen="$cli"; source="命令行参数"; }
  printf -v "$name" '%s' "$chosen"
  printf -v "${name}_SRC" '%s' "$source"
}

# -----------------------------------------------------------------------------
# 从实例上已生效的服务配置里读运行参数
# -----------------------------------------------------------------------------
vllm_unit_path() {
  local service="${SERVICE_NAME:-$SERVICE_NAME_DEFAULT}"
  printf '/etc/systemd/system/%s.service\n' "$service"
}

vllm_read_unit() {
  local unit exec_line flag value
  unit="$(vllm_unit_path)"
  UNIT_FILE="$unit"
  [ -f "$unit" ] || return 0

  UNIT_SERVICE_NAME="${SERVICE_NAME:-$SERVICE_NAME_DEFAULT}"
  exec_line="$(grep -m1 '^ExecStart=' "$unit" || true)"
  [ -n "$exec_line" ] || return 0

  # ExecStart 形如：<venv>/bin/python -m vllm.entrypoints.openai.api_server --model X --port N ...
  UNIT_VIRTUAL_ENV_DIR="$(printf '%s\n' "$exec_line" | sed -n 's#^\(.*\)/bin/[^/][^/]*/python .*$#\1#p')"

  for flag in model port max-model-len tensor-parallel-size gpu-memory-utilization; do
    value="$(printf '%s\n' "$exec_line" | sed -n "s/.*--${flag}=\([^ ]*\).*/\1/p")"
    [ -n "$value" ] || value="$(printf '%s\n' "$exec_line" | sed -n "s/.*--${flag} \([^ ]*\).*/\1/p")"
    case "$flag" in
      model) UNIT_MODEL_NAME="$value" ;;
      port) UNIT_VLLM_PORT="$value" ;;
      max-model-len) UNIT_MAX_MODEL_LEN="$value" ;;
      tensor-parallel-size) UNIT_TENSOR_PARALLEL_SIZE="$value" ;;
      gpu-memory-utilization) UNIT_GPU_MEMORY_UTILIZATION="$value" ;;
    esac
  done

  UNIT_MODEL_CACHE_DIR="$(grep -m1 '^Environment=HF_HOME=' "$unit" | sed 's/^Environment=HF_HOME=//')"
  UNIT_MODEL_SOURCE_BASE_URL="$(grep -m1 '^Environment=HF_ENDPOINT=' "$unit" | sed 's/^Environment=HF_ENDPOINT=//')"
}

# -----------------------------------------------------------------------------
# 按优先级合成最终参数
# -----------------------------------------------------------------------------
vllm_finalize_params() {
  vllm_pick SERVICE_NAME              "$CLI_SERVICE_NAME"              "${SERVICE_NAME__ENV}"              "${UNIT_SERVICE_NAME}"              "$SERVICE_NAME_DEFAULT"
  vllm_pick VIRTUAL_ENV_DIR           "$CLI_VIRTUAL_ENV_DIR"           "${VIRTUAL_ENV_DIR__ENV}"           "${UNIT_VIRTUAL_ENV_DIR}"           "$VIRTUAL_ENV_DIR_DEFAULT"
  vllm_pick DATA_DISK_MOUNT_POINT     "$CLI_DATA_DISK_MOUNT_POINT"     "${DATA_DISK_MOUNT_POINT__ENV}"     "${UNIT_DATA_DISK_MOUNT_POINT}"     "$DATA_DISK_MOUNT_POINT_DEFAULT"
  vllm_pick MODEL_NAME                "$CLI_MODEL_NAME"                "${MODEL_NAME__ENV}"                "${UNIT_MODEL_NAME}"                "$MODEL_NAME_DEFAULT"
  vllm_pick MODEL_CACHE_DIR           "$CLI_MODEL_CACHE_DIR"           "${MODEL_CACHE_DIR__ENV}"           "${UNIT_MODEL_CACHE_DIR}"           "$MODEL_CACHE_DIR_DEFAULT"
  vllm_pick MODEL_SOURCE_BASE_URL     "$CLI_MODEL_SOURCE_BASE_URL"     "${MODEL_SOURCE_BASE_URL__ENV}"     "${UNIT_MODEL_SOURCE_BASE_URL}"     "$MODEL_SOURCE_BASE_URL_DEFAULT"
  vllm_pick PYTHON_PACKAGE_INDEX_URL  "$CLI_PYTHON_PACKAGE_INDEX_URL"  "${PYTHON_PACKAGE_INDEX_URL__ENV}"  "${UNIT_PYTHON_PACKAGE_INDEX_URL}"  "$PYTHON_PACKAGE_INDEX_URL_DEFAULT"
  vllm_pick VLLM_VERSION              "$CLI_VLLM_VERSION"              "${VLLM_VERSION__ENV}"              "${UNIT_VLLM_VERSION}"              "$VLLM_VERSION_DEFAULT"
  vllm_pick VLLM_PORT                 "$CLI_VLLM_PORT"                 "${VLLM_PORT__ENV}"                 "${UNIT_VLLM_PORT}"                 "$VLLM_PORT_DEFAULT"
  vllm_pick MAX_MODEL_LEN             "$CLI_MAX_MODEL_LEN"             "${MAX_MODEL_LEN__ENV}"             "${UNIT_MAX_MODEL_LEN}"             "$MAX_MODEL_LEN_DEFAULT"
  vllm_pick GPU_MEMORY_UTILIZATION    "$CLI_GPU_MEMORY_UTILIZATION"    "${GPU_MEMORY_UTILIZATION__ENV}"    "${UNIT_GPU_MEMORY_UTILIZATION}"    "$GPU_MEMORY_UTILIZATION_DEFAULT"
  vllm_pick TENSOR_PARALLEL_SIZE      "$CLI_TENSOR_PARALLEL_SIZE"      "${TENSOR_PARALLEL_SIZE__ENV}"      "${UNIT_TENSOR_PARALLEL_SIZE}"      "$TENSOR_PARALLEL_SIZE_DEFAULT"
  vllm_pick BOOTSTRAP_LOG_PATH        "$CLI_BOOTSTRAP_LOG_PATH"        "${BOOTSTRAP_LOG_PATH__ENV}"        "${UNIT_BOOTSTRAP_LOG_PATH}"        "$BOOTSTRAP_LOG_PATH_DEFAULT"
  UNIT_FILE="$(vllm_unit_path)"
}

# -----------------------------------------------------------------------------
# 取值合法性检查：不合法就直接中止，避免把无效参数写进服务配置
# -----------------------------------------------------------------------------
vllm_validate_params() {
  local name
  [ -n "$MODEL_NAME" ] || vllm_die "MODEL_NAME（对应 var.model_name）不能为空。" 1
  [ "$TENSOR_PARALLEL_SIZE" -gt 0 ] 2>/dev/null || vllm_die "TENSOR_PARALLEL_SIZE（对应 var.tensor_parallel_size）需为正整数，当前取值：${TENSOR_PARALLEL_SIZE}" 1
  [ "$MAX_MODEL_LEN" -gt 0 ] 2>/dev/null || vllm_die "MAX_MODEL_LEN（对应 var.max_model_len）需为正整数，当前取值：${MAX_MODEL_LEN}" 1
  [ "$VLLM_PORT" -ge 1 ] 2>/dev/null && [ "$VLLM_PORT" -le 65535 ] 2>/dev/null \
    || vllm_die "VLLM_PORT（对应 var.vllm_port）取值范围 1-65535，当前取值：${VLLM_PORT}" 1
  printf '%s\n' "$GPU_MEMORY_UTILIZATION" | grep -Eq '^(0|1|0?\.[0-9]+)$' \
    || vllm_die "GPU_MEMORY_UTILIZATION（对应 var.gpu_memory_utilization）需为 0 到 1 之间的小数，当前取值：${GPU_MEMORY_UTILIZATION}" 1
  case "$MODEL_CACHE_DIR" in
    /*) ;;
    *) vllm_die "MODEL_CACHE_DIR（对应 var.model_cache_dir）需是绝对路径，当前取值：${MODEL_CACHE_DIR}" 1 ;;
  esac
  case "$BOOTSTRAP_LOG_PATH" in
    /*) ;;
    *) vllm_die "BOOTSTRAP_LOG_PATH（对应 var.bootstrap_log_path）需是绝对路径，当前取值：${BOOTSTRAP_LOG_PATH}" 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# 打印最终生效的参数与来源
# -----------------------------------------------------------------------------
vllm_print_params() {
  local name
  vllm_note "推理服务运行参数（生效取值 / 来源）："
  for name in SERVICE_NAME VIRTUAL_ENV_DIR MODEL_NAME MODEL_CACHE_DIR MODEL_SOURCE_BASE_URL \
              PYTHON_PACKAGE_INDEX_URL VLLM_VERSION VLLM_PORT MAX_MODEL_LEN GPU_MEMORY_UTILIZATION \
              TENSOR_PARALLEL_SIZE BOOTSTRAP_LOG_PATH DATA_DISK_MOUNT_POINT; do
    printf '  %-24s = %-34s (%s)\n' "$name" "$(eval "printf '%s' \"\${$name}\"")" "$(eval "printf '%s' \"\${${name}_SRC:-未知}\"")"
  done
}

# -----------------------------------------------------------------------------
# 生成服务配置内容：与实例初始化阶段写入的服务配置逐行同形
# -----------------------------------------------------------------------------
vllm_render_unit() {
  cat <<UNIT
[Unit]
Description=vLLM OpenAI compatible inference service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HF_HOME=${MODEL_CACHE_DIR}
Environment=HF_ENDPOINT=${MODEL_SOURCE_BASE_URL}
Environment=HF_HUB_ENABLE_HF_TRANSFER=0
ExecStart=${VIRTUAL_ENV_DIR}/bin/python -m vllm.entrypoints.openai.api_server --model ${MODEL_NAME} --host 0.0.0.0 --port ${VLLM_PORT} --tensor-parallel-size ${TENSOR_PARALLEL_SIZE} --max-model-len ${MAX_MODEL_LEN} --gpu-memory-utilization ${GPU_MEMORY_UTILIZATION} --enable-prefix-caching
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
}

# -----------------------------------------------------------------------------
# 健康探测与就绪等待
# -----------------------------------------------------------------------------
vllm_health_url() {
  printf 'http://127.0.0.1:%s/health\n' "$VLLM_PORT"
}

# 输出 HTTP 状态码；连不上输出 000，本机无 curl 输出 n/a
vllm_health_code() {
  command -v curl >/dev/null 2>&1 || { printf 'n/a'; return 0; }
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(vllm_health_url)" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

# vllm_wait_ready <秒>：在窗口内每 10 秒探测一次 /health
# 就绪返回 0；超出窗口返回 1（调用方据此决定是继续等待还是排查）
vllm_wait_ready() {
  local timeout="${1:-$READY_TIMEOUT_DEFAULT}" deadline code waited=0
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    code="$(vllm_health_code)"
    if [ "$code" = "200" ]; then
      vllm_note "推理服务已就绪：$(vllm_health_url) 返回 200（已等待 ${waited}s）。"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      vllm_note "等待 ${timeout}s 后仍未就绪：$(vllm_health_url) 返回 ${code}。"
      return 1
    fi
    sleep 10
    waited=$(( waited + 10 ))
    [ $(( waited % 60 )) -eq 0 ] && vllm_note "仍在等待（已 ${waited}s，剩余窗口 $(( deadline - $(date +%s) ))s），当前 /health 返回 ${code}。首次启动需下载并加载模型权重。"
  done
}

# -----------------------------------------------------------------------------
# 运行前置条件检查
# -----------------------------------------------------------------------------
vllm_require_systemd_root() {
  command -v systemctl >/dev/null 2>&1 \
    || vllm_die "本机没有 systemctl：本脚本在推理实例内执行，请在实例上以 root 身份运行。" 2
  [ "$(id -u)" = "0" ] \
    || vllm_die "需要 root 权限才能管理系统服务，请在命令前加 sudo。" 2
}

vllm_require_runtime() {
  [ -x "${VIRTUAL_ENV_DIR}/bin/python" ] || {
    vllm_note "未找到推理框架的运行环境目录：${VIRTUAL_ENV_DIR}"
    vllm_note "实例初始化脚本会创建该目录并安装 vllm==${VLLM_VERSION}（软件包索引 ${PYTHON_PACKAGE_INDEX_URL}）。"
    vllm_note "请先查看初始化日志确认进度：cat ${BOOTSTRAP_LOG_PATH}"
    vllm_die "运行环境缺失，无法启动推理服务。" 4
  }
}

# 服务未由 systemd 托管时的提示（推理服务只监听实例本机与 VPC 内）
vllm_access_hint() {
  vllm_note "本地调用前需先建立端口转发（运维终端执行，保持窗口常驻）："
  vllm_note "  ssh -i <本地私钥文件> -N -L ${VLLM_PORT}:<实例私网IP>:${VLLM_PORT} root@<实例公网IP>"
  vllm_note "随后：curl -s -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:${VLLM_PORT}/health"
}

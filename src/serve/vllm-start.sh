#!/usr/bin/env bash
# =============================================================================
# 启动（或按新参数重启）推理实例上的 vLLM 推理服务
#   在推理实例内以 root 身份执行。运行参数按「命令行 > 同名环境变量 > 实例上已生效
#   的服务配置 > 默认值」取值，取值名与 infra/variables.tf 的输入变量一一对应，
#   详见同目录 vllm-env.sh 的说明。
#
# 用法：
#   ./vllm-start.sh [选项]
# 选项：
#   --model <名称>                        模型名称，对应 var.model_name
#   --max-model-len <整数>                最大序列长度，对应 var.max_model_len
#   --gpu-memory-utilization <小数>       显存分配比例，对应 var.gpu_memory_utilization
#   --tensor-parallel-size <整数>         张量并行的显卡数，对应 var.tensor_parallel_size
#   --port <整数>                         监听端口，对应 var.vllm_port
#   --model-cache-dir <路径>              权重缓存目录，对应 var.model_cache_dir
#   --model-source-base-url <地址>        权重下载源，对应 var.model_source_base_url
#   --python-package-index-url <地址>     软件包索引地址，对应 var.python_package_index_url
#   --vllm-version <版本>                 推理框架版本，对应 var.vllm_version
#   --bootstrap-log-path <路径>           初始化日志路径，对应 var.bootstrap_log_path
#   --service <名称>                      systemd 服务名，对应 output.service_name
#   --venv-dir <路径>                     推理框架运行环境目录
#   --data-disk-mount-point <路径>        数据盘挂载点，对应 local.data_disk_mount_point
#   --wait-seconds <整数>                 就绪等待窗口，默认 600
#   --no-wait                             只拉起服务，不等待 /health 返回 200
#   --dry-run                             只打印生效参数与服务配置内容，不做任何变更
#   -h, --help                            显示用法
# 依赖：bash 4+、curl、systemd（systemctl）、实例内已装好的推理框架运行环境。
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vllm-env.sh
. "${SRC_DIR}/vllm-env.sh"

WAIT=1
WAIT_SECONDS="$READY_TIMEOUT_DEFAULT"
DRY_RUN=0

usage() {
  awk 'NR > 1 && /^set -euo/ { exit } /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

vllm_capture_env

while [ $# -gt 0 ]; do
  case "$1" in
    --model) CLI_MODEL_NAME="${2:?--model 需要取值}"; shift 2 ;;
    --max-model-len) CLI_MAX_MODEL_LEN="${2:?--max-model-len 需要取值}"; shift 2 ;;
    --gpu-memory-utilization) CLI_GPU_MEMORY_UTILIZATION="${2:?--gpu-memory-utilization 需要取值}"; shift 2 ;;
    --tensor-parallel-size) CLI_TENSOR_PARALLEL_SIZE="${2:?--tensor-parallel-size 需要取值}"; shift 2 ;;
    --port) CLI_VLLM_PORT="${2:?--port 需要取值}"; shift 2 ;;
    --model-cache-dir) CLI_MODEL_CACHE_DIR="${2:?--model-cache-dir 需要取值}"; shift 2 ;;
    --model-source-base-url) CLI_MODEL_SOURCE_BASE_URL="${2:?--model-source-base-url 需要取值}"; shift 2 ;;
    --python-package-index-url) CLI_PYTHON_PACKAGE_INDEX_URL="${2:?--python-package-index-url 需要取值}"; shift 2 ;;
    --vllm-version) CLI_VLLM_VERSION="${2:?--vllm-version 需要取值}"; shift 2 ;;
    --bootstrap-log-path) CLI_BOOTSTRAP_LOG_PATH="${2:?--bootstrap-log-path 需要取值}"; shift 2 ;;
    --service) CLI_SERVICE_NAME="${2:?--service 需要取值}"; shift 2 ;;
    --venv-dir) CLI_VIRTUAL_ENV_DIR="${2:?--venv-dir 需要取值}"; shift 2 ;;
    --data-disk-mount-point) CLI_DATA_DISK_MOUNT_POINT="${2:?--data-disk-mount-point 需要取值}"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="${2:?--wait-seconds 需要取值}"; shift 2 ;;
    --no-wait) WAIT=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) vllm_die "未识别的选项：$1（用 --help 查看用法）" 1 ;;
  esac
done

vllm_read_unit
vllm_finalize_params
vllm_validate_params
[ "$WAIT_SECONDS" -ge 0 ] 2>/dev/null || vllm_die "--wait-seconds 需为非负整数，当前取值：${WAIT_SECONDS}" 1

vllm_print_params
vllm_note ""
vllm_note "服务配置目标路径：${UNIT_FILE}"

if [ "$DRY_RUN" = "1" ]; then
  vllm_note ""
  vllm_note "以下为本脚本会写入的服务配置内容（--dry-run，未做任何变更）："
  vllm_note "--------------------------------------------------------------------------"
  vllm_render_unit
  vllm_note "--------------------------------------------------------------------------"
  exit 0
fi

vllm_require_systemd_root
vllm_require_runtime

TMP_UNIT="$(mktemp)"
trap 'rm -f "$TMP_UNIT"' EXIT
vllm_render_unit > "$TMP_UNIT"

CHANGED=0
if [ ! -f "$UNIT_FILE" ]; then
  vllm_note "服务配置不存在，将按上面的参数新建。"
  CHANGED=1
elif ! cmp -s "$TMP_UNIT" "$UNIT_FILE"; then
  vllm_note "服务配置与当前参数不一致，将更新并重启服务。"
  cp -f "$UNIT_FILE" "${UNIT_FILE}.bak" && vllm_note "原配置已备份到 ${UNIT_FILE}.bak"
  CHANGED=1
else
  vllm_note "服务配置与当前参数一致。"
fi

if [ "$CHANGED" = "1" ]; then
  install -m 0644 "$TMP_UNIT" "$UNIT_FILE"
  systemctl daemon-reload
fi

if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl enable "$SERVICE_NAME"
  vllm_note "已设置开机自启：systemctl enable ${SERVICE_NAME}"
fi

if [ "$CHANGED" = "1" ] || systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl restart "$SERVICE_NAME"
  vllm_note "已重启服务：systemctl restart ${SERVICE_NAME}"
else
  systemctl start "$SERVICE_NAME"
  vllm_note "已启动服务：systemctl start ${SERVICE_NAME}"
fi

vllm_note "服务状态：$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"

if [ "$WAIT" = "1" ]; then
  vllm_note "开始探测 $(vllm_health_url)，等待窗口 ${WAIT_SECONDS}s（首次启动需下载并加载模型权重，通常需要 8 到 15 分钟）。"
  if ! vllm_wait_ready "$WAIT_SECONDS"; then
    vllm_note "服务仍在加载权重或已异常退出，按下面两条排查（本脚本不因此中止，服务由 systemd 持续拉起）。"
  fi
else
  vllm_note "--no-wait：不等待就绪。稍后可用 src/serve/vllm-status.sh 查看状态。"
fi

vllm_note ""
vllm_note "下一步排查与验证："
vllm_note "  src/serve/vllm-status.sh                 查看服务与接口状态"
vllm_note "  src/serve/vllm-logs.sh -n 50             查看最近 50 行服务日志"
vllm_access_hint

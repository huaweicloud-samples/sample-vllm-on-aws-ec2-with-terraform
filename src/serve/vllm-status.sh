#!/usr/bin/env bash
# =============================================================================
# 查看推理服务运行状态：systemd 服务状态 + 接口健康 + 已加载模型 + 端口监听 + 显存占用
#   在推理实例内执行可看到完整信息；在运维本地执行（已建立端口转发时）会自动跳过
#   systemd 与显存两项，只做接口侧探测。
#   只读脚本，不修改任何配置。
#
# 用法：
#   ./vllm-status.sh [--port <整数>] [--service <名称>] [--no-curl]
# 选项：
#   --port <整数>     探测端口，对应 var.vllm_port
#   --service <名称>  systemd 服务名，对应 output.service_name
#   --no-curl         跳过接口探测（无 curl 或需要完全离线时）
#   -h, --help        显示用法
# 可用环境变量：SERVICE_NAME / VLLM_PORT / MODEL_NAME / MODEL_CACHE_DIR /
#               DATA_DISK_MOUNT_POINT / BOOTSTRAP_LOG_PATH / VIRTUAL_ENV_DIR / VLLM_VERSION
# 退出码：0 健康检查返回 200；1 其他情况（原因逐行写明）
# 依赖：bash 4+、curl（接口探测）、systemd（实例内）、nvidia-smi（实例内，随 GPU 驱动而来）。
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vllm-env.sh
. "${SRC_DIR}/vllm-env.sh"

USE_CURL=1

usage() {
  awk 'NR > 1 && /^set -euo/ { exit } /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

vllm_capture_env

while [ $# -gt 0 ]; do
  case "$1" in
    --port) CLI_VLLM_PORT="${2:?--port 需要取值}"; shift 2 ;;
    --service) CLI_SERVICE_NAME="${2:?--service 需要取值}"; shift 2 ;;
    --no-curl) USE_CURL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) vllm_die "未识别的选项：$1（用 --help 查看用法）" 1 ;;
  esac
done

vllm_read_unit
vllm_finalize_params
vllm_validate_params

FAILED=0
line() { printf '%-26s %s\n' "$1" "$2"; }

vllm_note "== 推理服务状态（端口 ${VLLM_PORT}，模型 ${MODEL_NAME}）=="

# -----------------------------------------------------------------------------
# 1. systemd 服务状态（仅实例内可见）
# -----------------------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  STATE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  ENABLED="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  line "systemd 服务" "${SERVICE_NAME}.service：${STATE}（开机自启 ${ENABLED}）"
  [ "$STATE" = "active" ] || FAILED=1
  if [ "$STATE" != "active" ]; then
    line "" "服务未运行：执行 src/serve/vllm-start.sh 拉起，或 src/serve/vllm-logs.sh 看原因。"
  fi
else
  line "systemd 服务" "本机无 systemctl：跳过（这些字段需在推理实例内查看）"
fi

# -----------------------------------------------------------------------------
# 2. 服务配置与服务文件
# -----------------------------------------------------------------------------
if [ -n "${UNIT_FILE:-}" ] && [ -f "$UNIT_FILE" ]; then
  line "服务配置" "${UNIT_FILE} 已存在"
else
  line "服务配置" "未找到 ${UNIT_FILE:-未知路径}：实例初始化脚本可能尚未完成，见 ${BOOTSTRAP_LOG_PATH}"
fi

# -----------------------------------------------------------------------------
# 3. 运行环境与框架版本（仅实例内可见）
# -----------------------------------------------------------------------------
if [ -x "${VIRTUAL_ENV_DIR}/bin/python" ]; then
  INSTALLED="$("${VIRTUAL_ENV_DIR}/bin/python" -c 'import vllm; print(getattr(vllm, "__version__", "未知"))' 2>/dev/null || echo "导入失败")"
  line "推理框架版本" "已装 ${INSTALLED}，部署声明 var.vllm_version=${VLLM_VERSION}"
  [ "$INSTALLED" = "$VLLM_VERSION" ] || line "" "版本与部署声明不一致：以实例内实际版本为准，或改 infra 侧取值后重新部署。"
else
  line "推理框架版本" "未找到 ${VIRTUAL_ENV_DIR}/bin/python：实例初始化脚本可能尚未装完，见 ${BOOTSTRAP_LOG_PATH}"
fi

# -----------------------------------------------------------------------------
# 4. 端口监听
# -----------------------------------------------------------------------------
if command -v ss >/dev/null 2>&1; then
  LISTEN="$(ss -ltn 2>/dev/null | grep -c ":${VLLM_PORT} " || true)"
  [ "${LISTEN:-0}" -gt 0 ] 2>/dev/null \
    && line "端口监听" "${VLLM_PORT} 正在监听" \
    || line "端口监听" "${VLLM_PORT} 未监听（进程仍在加载权重，或已退出）"
elif command -v netstat >/dev/null 2>&1; then
  LISTEN="$(netstat -ltn 2>/dev/null | grep -c ":${VLLM_PORT} " || true)"
  [ "${LISTEN:-0}" -gt 0 ] 2>/dev/null \
    && line "端口监听" "${VLLM_PORT} 正在监听" \
    || line "端口监听" "${VLLM_PORT} 未监听（进程仍在加载权重，或已退出）"
else
  line "端口监听" "本机无 ss / netstat：跳过"
fi

# -----------------------------------------------------------------------------
# 5. 显存占用（仅在能读到 GPU 驱动时）
# -----------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU="$(nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader 2>/dev/null | paste -d'; ' - - 2>/dev/null || true)"
  if [ -n "$GPU" ]; then
    line "显存占用" "${GPU}"
    line "" "张量并行度声明 var.tensor_parallel_size=${TENSOR_PARALLEL_SIZE}，需与卡数一致。"
  else
    line "显存占用" "nvidia-smi 可执行但读不到数据"
  fi
else
  line "显存占用" "本机无 nvidia-smi：跳过（实例内需由预装 GPU 驱动的镜像提供）"
fi

# -----------------------------------------------------------------------------
# 6. 权重缓存目录与磁盘占用
# -----------------------------------------------------------------------------
if [ -d "$MODEL_CACHE_DIR" ]; then
  line "权重缓存目录" "${MODEL_CACHE_DIR} 存在"
  command -v df >/dev/null 2>&1 && line "  磁盘占用" "$(df -h "$MODEL_CACHE_DIR" 2>/dev/null | tail -1)"
else
  line "权重缓存目录" "${MODEL_CACHE_DIR} 尚不存在（首次请求前会由权重下载创建；数据盘挂载点 ${DATA_DISK_MOUNT_POINT}）"
fi

# -----------------------------------------------------------------------------
# 7. 接口探测：/health 与 /v1/models
# -----------------------------------------------------------------------------
if [ "$USE_CURL" = "1" ] && command -v curl >/dev/null 2>&1; then
  CODE="$(vllm_health_code)"
  line "GET /health" "${CODE}"
  if [ "$CODE" = "200" ]; then
    line "服务结论" "就绪"
  else
    FAILED=1
    line "服务结论" "未就绪（000 表示端口无响应；权重加载期间属正常现象）"
  fi

  MODELS="$(curl -s --max-time 5 "http://127.0.0.1:${VLLM_PORT}/v1/models" 2>/dev/null || true)"
  if [ -n "$MODELS" ] && printf '%s' "$MODELS" | grep -q '"id"'; then
    IDS="$(printf '%s' "$MODELS" | grep -o '"id":"[^"]*"' | sed 's/"id":"//; s/"$//' | tr '\n' ' ')"
    line "GET /v1/models" "${IDS}"
    printf '%s' "$IDS" | grep -qF -- "$MODEL_NAME" \
      || line "" "已加载模型与声明的 MODEL_NAME（${MODEL_NAME}）不一致，请求体里的 model 需与这里列出的名称完全相同。"
  else
    line "GET /v1/models" "无返回（服务未就绪时无需处理）"
  fi
else
  line "GET /health" "跳过接口探测"
fi

# -----------------------------------------------------------------------------
# 8. 进一步排查入口
# -----------------------------------------------------------------------------
vllm_note ""
vllm_note "日志：src/serve/vllm-logs.sh -n 50        初始化日志：${BOOTSTRAP_LOG_PATH}"
[ "$FAILED" -eq 0 ] || vllm_note "参数取值与来源：src/serve/vllm-start.sh --dry-run"
exit "$FAILED"

#!/usr/bin/env bash
# =============================================================================
# 停止推理实例上的 vLLM 推理服务
#   在推理实例内以 root 身份执行。
#   停止后 systemd 不再拉起进程；实例重启或执行 vllm-start.sh 后恢复。
#   注意：承载实例的伸缩组只做健康检查与自动替换，本脚本停的是实例内的服务进程，
#   不会影响伸缩组本身。
#
# 用法：
#   ./vllm-stop.sh [--service <名称>] [--keep-unit] [--dry-run]
# 选项：
#   --service <名称>   systemd 服务名，对应 output.service_name（默认与环境变量 SERVICE_NAME 一致）
#   --keep-unit        仅停止服务，不改动服务配置（默认行为即如此，保留此项便于脚本化调用）
#   --dry-run          只打印将要执行的动作，不做任何变更
#   -h, --help         显示用法
# 可用环境变量：SERVICE_NAME
# 依赖：bash 4+、systemd（systemctl）。
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vllm-env.sh
. "${SRC_DIR}/vllm-env.sh"

DRY_RUN=0

usage() {
  awk 'NR > 1 && /^set -euo/ { exit } /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

vllm_capture_env

while [ $# -gt 0 ]; do
  case "$1" in
    --service) CLI_SERVICE_NAME="${2:?--service 需要取值}"; shift 2 ;;
    --keep-unit) shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) vllm_die "未识别的选项：$1（用 --help 查看用法）" 1 ;;
  esac
done

vllm_read_unit
vllm_finalize_params

vllm_note "服务名 ${SERVICE_NAME}（来源：${SERVICE_NAME_SRC}），监听端口 ${VLLM_PORT}，配置路径 ${UNIT_FILE}"

if [ "$DRY_RUN" = "1" ]; then
  vllm_note "--dry-run：将执行 systemctl stop ${SERVICE_NAME}（未做任何变更）。"
  exit 0
fi

vllm_require_systemd_root

if [ ! -f "$UNIT_FILE" ]; then
  vllm_note "未找到服务配置 ${UNIT_FILE}：该实例上还没有由初始化脚本或 vllm-start.sh 建立的推理服务，无需停止。"
  exit 0
fi

BEFORE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
vllm_note "停止前状态：${BEFORE}"

systemctl stop "$SERVICE_NAME"
AFTER="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
vllm_note "停止后状态：${AFTER}（预期 inactive）"

CODE="$(vllm_health_code)"
vllm_note "端口 ${VLLM_PORT} 的健康检查返回：${CODE}（000 表示端口已不再监听）"

if [ "$AFTER" = "active" ]; then
  vllm_die "服务仍处于运行状态，请执行 src/serve/vllm-logs.sh -n 100 查看原因。" 3
fi

vllm_note ""
vllm_note "如需重新拉起：src/serve/vllm-start.sh"
vllm_note "如需确认进程与显存占用：nvidia-smi"

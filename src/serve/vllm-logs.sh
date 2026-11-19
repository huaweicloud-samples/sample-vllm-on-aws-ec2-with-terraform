#!/usr/bin/env bash
# =============================================================================
# 查看推理服务日志：systemd 收集的服务输出 + 实例首次启动的初始化日志
#   默认两类都看；--source 可只选一类。
#   在运维本地执行时（无 systemd）会自动退化为只看初始化日志，且提示需要登录实例。
#
# 用法：
#   ./vllm-logs.sh [-n <行数>] [-f] [--source <journal|bootstrap|all>] [--service <名称>]
# 选项：
#   -n <行数>            显示末尾多少行，默认 50
#   -f                   持续跟踪输出（Ctrl+C 退出）；跟踪对象优先为服务日志
#   --source journal     只看服务输出（journalctl -u <service>）
#   --source bootstrap   只看实例初始化日志（对应 var.bootstrap_log_path）
#   --source all         两类都看（默认）
#   --service <名称>     systemd 服务名，对应 output.service_name
#   -h, --help           显示用法
# 可用环境变量：SERVICE_NAME / BOOTSTRAP_LOG_PATH
# 依赖：bash 4+；服务输出需 journalctl（实例内）与 root 权限；初始化日志需登录实例后查看。
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vllm-env.sh
. "${SRC_DIR}/vllm-env.sh"

LINES=50
FOLLOW=0
SOURCE="all"

usage() {
  awk 'NR > 1 && /^set -euo/ { exit } /^#/ { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

vllm_capture_env

while [ $# -gt 0 ]; do
  case "$1" in
    -n) LINES="${2:?-n 需要行数}"; shift 2 ;;
    -f|--follow) FOLLOW=1; shift ;;
    --source) SOURCE="${2:?--source 需要取值}"; shift 2 ;;
    --service) CLI_SERVICE_NAME="${2:?--service 需要取值}"; shift 2 ;;
    --bootstrap-log-path) CLI_BOOTSTRAP_LOG_PATH="${2:?--bootstrap-log-path 需要取值}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) vllm_die "未识别的选项：$1（用 --help 查看用法）" 1 ;;
  esac
done

case "$SOURCE" in
  journal|bootstrap|all) ;;
  *) vllm_die "--source 只能是 journal / bootstrap / all，当前取值：${SOURCE}" 1 ;;
esac
[ "$LINES" -gt 0 ] 2>/dev/null || vllm_die "-n 需为正整数，当前取值：${LINES}" 1

vllm_read_unit
vllm_finalize_params

HAS_JOURNAL=0
command -v journalctl >/dev/null 2>&1 && HAS_JOURNAL=1

show_journal() {
  if [ "$HAS_JOURNAL" = "0" ]; then
    vllm_note "== 服务输出：本机无 journalctl，请在推理实例内执行本脚本（或 systemctl status ${SERVICE_NAME}）。"
    return 0
  fi
  vllm_note "== 服务输出：journalctl -u ${SERVICE_NAME} -n ${LINES} =="
  if [ "$FOLLOW" = "1" ]; then
    exec journalctl -u "$SERVICE_NAME" -n "$LINES" -f --no-pager
  fi
  if ! journalctl -u "$SERVICE_NAME" -n "$LINES" --no-pager 2>/dev/null; then
    vllm_note "读取失败：查看服务日志需要 root 权限，请在命令前加 sudo。"
    return 0
  fi
}

show_bootstrap() {
  vllm_note "== 初始化日志：${BOOTSTRAP_LOG_PATH}（末尾 ${LINES} 行） =="
  if [ ! -f "$BOOTSTRAP_LOG_PATH" ]; then
    vllm_note "文件不存在。该日志由实例首次启动时的初始化脚本写入；若在实例内仍看不到，"
    vllm_note "说明初始化脚本尚未开始执行（伸缩组可能仍在创建实例）。"
    return 0
  fi
  if [ "$FOLLOW" = "1" ] && [ "$HAS_JOURNAL" = "0" ]; then
    exec tail -n "$LINES" -F "$BOOTSTRAP_LOG_PATH"
  fi
  tail -n "$LINES" "$BOOTSTRAP_LOG_PATH" || vllm_note "读取失败：需要 root 权限，请在命令前加 sudo。"
}

case "$SOURCE" in
  journal)
    show_journal
    ;;
  bootstrap)
    show_bootstrap
    ;;
  all)
    if [ "$FOLLOW" = "1" ]; then
      vllm_note "-f 只跟踪一类输出：这里跟踪服务输出（journalctl）；只看初始化日志请加 --source bootstrap。"
      show_journal
    else
      show_journal
      vllm_note ""
      show_bootstrap
    fi
    ;;
esac

exit 0

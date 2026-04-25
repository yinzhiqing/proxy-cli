#!/usr/bin/env bash
set -euo pipefail

SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/sing-box/config-net-proxy.json}"
SINGBOX_PID_FILE="${SINGBOX_PID_FILE:-/tmp/sing-box-tun.pid}"

if ! command -v sudo >/dev/null 2>&1; then
  echo "错误: 未找到命令 'sudo'" >&2
  exit 1
fi

echo "停止 sing-box TUN..."
if [[ -f "${SINGBOX_PID_FILE}" ]]; then
  pid="$(sudo cat "${SINGBOX_PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && ps -p "${pid}" >/dev/null 2>&1; then
    sudo kill "${pid}" || true
    echo "已通过 PID 文件停止 sing-box (pid=${pid})"
  fi
  sudo rm -f "${SINGBOX_PID_FILE}" || true
fi

if pgrep -f "sing-box.*${SINGBOX_CONFIG}" >/dev/null 2>&1; then
  sudo pkill -f "sing-box.*${SINGBOX_CONFIG}" || true
  echo "已停止残留 sing-box 进程"
fi

echo "完成。"

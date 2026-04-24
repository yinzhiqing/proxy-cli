#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-1080}"
AUTO_SYSTEM_PROXY="${AUTO_SYSTEM_PROXY:-1}"
PID_FILE="${PID_FILE:-/tmp/ss-local.pid}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 未找到命令 '$1'" >&2
    exit 1
  fi
}

require_cmd sudo

echo "停止本地代理进程..."
if [[ -f "${PID_FILE}" ]]; then
  pid="$(sudo cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && ps -p "${pid}" >/dev/null 2>&1; then
    sudo kill "${pid}" || true
    sudo rm -f "${PID_FILE}" || true
    echo "已通过 PID 文件停止 ss-local (pid=${pid})。"
  else
    sudo rm -f "${PID_FILE}" || true
  fi
fi

if pgrep -f "ss-local.*-l ${LOCAL_PORT}" >/dev/null 2>&1; then
  sudo pkill -f "ss-local.*-l ${LOCAL_PORT}" || true
  echo "已按端口 ${LOCAL_PORT} 停止残留 ss-local 进程。"
fi

if [[ "${AUTO_SYSTEM_PROXY}" == "1" ]] && command -v gsettings >/dev/null 2>&1; then
  if gsettings writable org.gnome.system.proxy mode >/dev/null 2>&1; then
    echo "关闭 GNOME 系统代理..."
    gsettings set org.gnome.system.proxy mode 'none'
    echo "GNOME 系统代理已关闭。"
  else
    echo "检测到 gsettings，但当前环境不可写系统代理，已跳过。"
  fi
else
  echo "未启用或不支持自动系统代理关闭（AUTO_SYSTEM_PROXY=${AUTO_SYSTEM_PROXY}）。"
fi

echo "完成。"

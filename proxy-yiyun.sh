#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/shadowsocks-libev/client.json}"
LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-1080}"
AUTO_SYSTEM_PROXY="${AUTO_SYSTEM_PROXY:-1}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 未找到命令 '$1'" >&2
    exit 1
  fi
}

require_ss_local() {
  if command -v ss-local >/dev/null 2>&1; then
    return 0
  fi
  echo "错误: 未找到命令 'ss-local'（由 shadowsocks-libev 提供）。" >&2
  echo >&2
  echo "安装示例:" >&2
  echo "  Debian/Ubuntu: sudo apt install shadowsocks-libev" >&2
  echo "  Fedora/RHEL:   sudo dnf install shadowsocks-libev" >&2
  echo "  Arch Linux:    sudo pacman -S shadowsocks-libev" >&2
  echo >&2
  echo "安装后需准备客户端 JSON，默认: ${CONFIG_FILE}" >&2
  echo "自定义路径: CONFIG_FILE=/path/to/client.json ./proxy.sh up" >&2
  exit 1
}

require_ss_local
require_cmd sudo

if ! sudo test -r "${CONFIG_FILE}"; then
  echo "错误: 无法读取配置文件: ${CONFIG_FILE}" >&2
  echo "请创建该文件或设置 CONFIG_FILE 指向有效 JSON（server、server_port、method、password 等）。" >&2
  exit 1
fi

# 如果已存在相同端口的 ss-local，先结束，避免重复启动。
if pgrep -f "ss-local.*-l ${LOCAL_PORT}" >/dev/null 2>&1; then
  echo "检测到旧的 ss-local 进程，正在停止..."
  sudo pkill -f "ss-local.*-l ${LOCAL_PORT}" || true
  sleep 1
fi

echo "启动 Shadowsocks 本地代理: ${LOCAL_HOST}:${LOCAL_PORT}"
if ! sudo ss-local -c "${CONFIG_FILE}" -b "${LOCAL_HOST}" -l "${LOCAL_PORT}" -u -f /tmp/ss-local.pid -v; then
  echo >&2
  echo "提示: 若启动失败，请核对 ${CONFIG_FILE} 中的 server、server_port、method、password 是否与远端一致，并检查本机端口 ${LOCAL_PORT} 是否被占用。" >&2
  exit 1
fi

# 当前 shell 可直接使用的代理环境变量（对当前脚本进程有效）。
export ALL_PROXY="socks5h://${LOCAL_HOST}:${LOCAL_PORT}"
export all_proxy="${ALL_PROXY}"
export HTTP_PROXY="${ALL_PROXY}"
export HTTPS_PROXY="${ALL_PROXY}"
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
echo "已设置当前会话代理环境变量。"

# 尝试自动配置 GNOME 系统代理，避免手工打开系统代理开关。
if [[ "${AUTO_SYSTEM_PROXY}" == "1" ]] && command -v gsettings >/dev/null 2>&1; then
  if gsettings writable org.gnome.system.proxy mode >/dev/null 2>&1; then
    echo "配置 GNOME 系统代理..."
    gsettings set org.gnome.system.proxy mode 'manual'
    gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '::1']"
    gsettings set org.gnome.system.proxy.socks host "${LOCAL_HOST}"
    gsettings set org.gnome.system.proxy.socks port "${LOCAL_PORT}"
    echo "GNOME 系统代理已开启（SOCKS5 ${LOCAL_HOST}:${LOCAL_PORT}）。"
  else
    echo "检测到 gsettings，但当前环境不可写系统代理，已跳过。"
  fi
else
  echo "未启用或不支持自动系统代理配置（AUTO_SYSTEM_PROXY=${AUTO_SYSTEM_PROXY}）。"
fi

echo "完成。"


#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/shadowsocks-libev/client.json}"
LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-1080}"
AUTO_SYSTEM_PROXY="${AUTO_SYSTEM_PROXY:-1}"
ENABLE_HTTP_PROXY="${ENABLE_HTTP_PROXY:-1}"
HTTP_PROXY_HOST="${HTTP_PROXY_HOST:-127.0.0.1}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-8118}"
PRIVOXY_CONFIG="${PRIVOXY_CONFIG:-/etc/privoxy/config}"
PRIVOXY_PID_FILE="${PRIVOXY_PID_FILE:-/tmp/privoxy.pid}"
PRIVOXY_LOG_FILE="${PRIVOXY_LOG_FILE:-/tmp/privoxy.log}"
PRIVOXY_MANAGED_BEGIN="# >>> net-proxy managed block >>>"
PRIVOXY_MANAGED_END="# <<< net-proxy managed block <<<"
http_proxy_ready=0

is_privoxy_running() {
  if pgrep -f "privoxy.*${PRIVOXY_CONFIG}" >/dev/null 2>&1; then
    return 0
  fi

  if command -v ss >/dev/null 2>&1 && ss -lnt | grep -Eq "127\.0\.0\.1:${HTTP_PROXY_PORT}|\[::1\]:${HTTP_PROXY_PORT}"; then
    return 0
  fi

  return 1
}

kill_pid() {
  local pid="$1"
  local owner

  owner="$(ps -o user= -p "${pid}" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "${owner}" ]]; then
    return 1
  fi

  if [[ "${owner}" == "${USER}" ]]; then
    kill "${pid}" >/dev/null 2>&1
  else
    sudo kill "${pid}" >/dev/null 2>&1
  fi
}

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

ensure_privoxy_config() {
  local tmp_file
  local existing_listen=""
  local existing_forward=""

  if ! sudo test -r "${PRIVOXY_CONFIG}"; then
    echo "警告: 无法读取 privoxy 配置文件 ${PRIVOXY_CONFIG}，已跳过 HTTP 代理。"
    return 1
  fi

  if ! sudo test -w "${PRIVOXY_CONFIG}"; then
    echo "警告: ${PRIVOXY_CONFIG} 不可写，无法自动修复配置。"
    echo "建议添加: listen-address  ${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
    echo "建议添加: forward-socks5t / ${LOCAL_HOST}:${LOCAL_PORT} ."
    return 1
  fi

  existing_listen="$(sudo grep -E "^[[:space:]]*listen-address[[:space:]]+${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}([[:space:]]|$)" "${PRIVOXY_CONFIG}" | head -n 1 || true)"
  existing_forward="$(sudo grep -E "^[[:space:]]*forward-socks5t[[:space:]]+/[[:space:]]+${LOCAL_HOST}:${LOCAL_PORT}[[:space:]]+\.([[:space:]]|$)" "${PRIVOXY_CONFIG}" | head -n 1 || true)"
  if [[ -n "${existing_listen}" && -n "${existing_forward}" ]]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  sudo awk -v begin="${PRIVOXY_MANAGED_BEGIN}" -v end="${PRIVOXY_MANAGED_END}" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "${PRIVOXY_CONFIG}" > "${tmp_file}"

  {
    printf '\n%s\n' "${PRIVOXY_MANAGED_BEGIN}"
    printf '# Managed by net-proxy. Remove this block if you want full manual control.\n'
    if [[ -n "${existing_listen}" ]]; then
      printf '# Existing listen-address already covers %s:%s\n' "${HTTP_PROXY_HOST}" "${HTTP_PROXY_PORT}"
    else
      printf 'listen-address  %s:%s\n' "${HTTP_PROXY_HOST}" "${HTTP_PROXY_PORT}"
    fi
    if [[ -n "${existing_forward}" ]]; then
      printf '# Existing forward-socks5t already covers %s:%s\n' "${LOCAL_HOST}" "${LOCAL_PORT}"
    else
      printf 'forward-socks5t / %s:%s .\n' "${LOCAL_HOST}" "${LOCAL_PORT}"
    fi
    printf '%s\n' "${PRIVOXY_MANAGED_END}"
  } >> "${tmp_file}"

  sudo cp "${tmp_file}" "${PRIVOXY_CONFIG}"
  rm -f "${tmp_file}"

  if [[ -z "${existing_listen}" || -z "${existing_forward}" ]]; then
    echo "已写入 privoxy 所需配置到 ${PRIVOXY_CONFIG}。"
  fi

  return 0
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

# 可选启动 privoxy，提供 HTTP 代理入口。
if [[ "${ENABLE_HTTP_PROXY}" == "1" ]]; then
  if ! command -v privoxy >/dev/null 2>&1; then
    echo "警告: 未找到 privoxy，已跳过 HTTP 代理。"
    echo "可安装: sudo apt install privoxy"
  else
    echo "检查并启动 HTTP 代理 (privoxy ${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT})..."
    if pgrep -f "privoxy.*${PRIVOXY_CONFIG}" >/dev/null 2>&1; then
      privoxy_pids="$(pgrep -f "privoxy.*${PRIVOXY_CONFIG}" || true)"
      if [[ -n "${privoxy_pids}" ]]; then
        while IFS= read -r pid; do
          [[ -n "${pid}" ]] || continue
          kill_pid "${pid}" || true
        done <<< "${privoxy_pids}"
      fi
      sleep 1
    fi
    if ensure_privoxy_config; then
      sudo rm -f "${PRIVOXY_PID_FILE}" || true
      sudo bash -c "nohup privoxy --no-daemon '${PRIVOXY_CONFIG}' >'${PRIVOXY_LOG_FILE}' 2>&1 & echo \$! > '${PRIVOXY_PID_FILE}'"
      sleep 1
      privoxy_pid="$(sudo cat "${PRIVOXY_PID_FILE}" 2>/dev/null || true)"
      if [[ -n "${privoxy_pid}" ]] && ps -p "${privoxy_pid}" >/dev/null 2>&1; then
        echo "HTTP 代理已启动: http://${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
        http_proxy_ready=1
      elif is_privoxy_running; then
        echo "HTTP 代理已启动: http://${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
        http_proxy_ready=1
      else
        echo "警告: privoxy 启动失败，请检查 ${PRIVOXY_CONFIG}。"
        if sudo test -r "${PRIVOXY_LOG_FILE}"; then
          echo "最近日志: ${PRIVOXY_LOG_FILE}"
          sudo tail -n 20 "${PRIVOXY_LOG_FILE}" || true
        fi
      fi
    fi
  fi
fi

# 当前 shell 可直接使用的代理环境变量（对当前脚本进程有效）。
if [[ "${ENABLE_HTTP_PROXY}" == "1" && "${http_proxy_ready}" == "1" ]]; then
  export HTTP_PROXY="http://${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
  export HTTPS_PROXY="${HTTP_PROXY}"
else
  export HTTP_PROXY="socks5h://${LOCAL_HOST}:${LOCAL_PORT}"
  export HTTPS_PROXY="${HTTP_PROXY}"
fi
export ALL_PROXY="socks5h://${LOCAL_HOST}:${LOCAL_PORT}"
export all_proxy="${ALL_PROXY}"
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


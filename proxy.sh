#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
UP_SCRIPT="${BASE_DIR}/proxy-yiyun.sh"
DOWN_SCRIPT="${BASE_DIR}/proxy-off.sh"
TUN_UP_SCRIPT="${BASE_DIR}/proxy-tun-up.sh"
TUN_DOWN_SCRIPT="${BASE_DIR}/proxy-tun-down.sh"
LOCAL_PORT="${LOCAL_PORT:-1080}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-8118}"
LOCAL_HOST="${LOCAL_HOST:-127.0.0.1}"
HTTP_PROXY_HOST="${HTTP_PROXY_HOST:-127.0.0.1}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.gstatic.com/generate_204}"
PRIVOXY_CONFIG="${PRIVOXY_CONFIG:-/etc/privoxy/config}"
TUN_INTERFACE="${TUN_INTERFACE:-sb-tun}"
SINGBOX_LOG_FILE="${SINGBOX_LOG_FILE:-/tmp/sing-box-tun.log}"
SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/sing-box/config-net-proxy.json}"

usage() {
  cat <<'EOF'
用法:
  ./proxy.sh up       启动代理
  ./proxy.sh down     关闭代理
  ./proxy.sh restart  重启代理
  ./proxy.sh status   查看代理状态
  ./proxy.sh test     测试 SOCKS5/HTTP 代理连通性
  ./proxy.sh check    检查 DNS/TCP/HTTP 连通性
  ./proxy.sh tun-up   启动 TUN 全局代理（sing-box）
  ./proxy.sh tun-down 关闭 TUN 全局代理（sing-box）
  ./proxy.sh tun-restart 重启 TUN 全局代理（sing-box）
  ./proxy.sh tun-status 查看 TUN 代理状态
  ./proxy.sh tun-test 测试 TUN 连通性（含 ping）
  ./proxy.sh env      输出代理环境变量（配合 eval 使用）
  ./proxy.sh env --unset  输出清理代理环境变量命令
  ./proxy.sh install  安装 proxy 命令到 ~/.local/bin
  ./proxy.sh uninstall 卸载 ~/.local/bin/proxy
EOF
}

status() {
  echo "== ss-local 进程状态 =="
  if pgrep -f "ss-local.*-l ${LOCAL_PORT}" >/dev/null 2>&1; then
    echo "运行中 (端口: ${LOCAL_PORT})"
  else
    echo "未运行"
  fi

  echo
  echo "== HTTP 代理状态 (privoxy) =="
  if pgrep -f "privoxy.*config" >/dev/null 2>&1; then
    echo "运行中 (端口: ${HTTP_PROXY_PORT})"
  else
    echo "未运行"
  fi

  echo
  echo "== 系统代理状态 (GNOME) =="
  if command -v gsettings >/dev/null 2>&1; then
    if gsettings writable org.gnome.system.proxy mode >/dev/null 2>&1; then
      mode="$(gsettings get org.gnome.system.proxy mode || true)"
      socks_host="$(gsettings get org.gnome.system.proxy.socks host || true)"
      socks_port="$(gsettings get org.gnome.system.proxy.socks port || true)"
      echo "mode: ${mode}"
      echo "socks host: ${socks_host}"
      echo "socks port: ${socks_port}"
    else
      echo "当前环境不支持写入/读取 GNOME 代理设置。"
    fi
  else
    echo "未安装 gsettings。"
  fi
}

test_proxy() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "错误: 未找到命令 'curl'，无法执行连通性测试。"
    return 1
  fi

  local rc=0
  echo "测试目标: ${PROXY_TEST_URL}"
  echo

  echo "== SOCKS5 测试 (${LOCAL_HOST}:${LOCAL_PORT}) =="
  if curl --silent --show-error --fail --max-time 10 --socks5-hostname "${LOCAL_HOST}:${LOCAL_PORT}" "${PROXY_TEST_URL}" >/dev/null; then
    echo "SOCKS5 测试通过"
  else
    echo "SOCKS5 测试失败"
    rc=1
  fi

  echo
  echo "== HTTP 测试 (${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}) =="
  if curl --silent --show-error --fail --max-time 10 -x "http://${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}" "${PROXY_TEST_URL}" >/dev/null; then
    echo "HTTP 测试通过"
  else
    echo "HTTP 测试失败（请确认 privoxy 已安装、已启动且配置了 forward-socks5t）"
    echo
    echo "== HTTP 失败诊断 =="
    if command -v privoxy >/dev/null 2>&1; then
      echo "privoxy 命令: 已安装"
    else
      echo "privoxy 命令: 未安装（可执行: sudo apt install privoxy）"
    fi
    if pgrep -f "privoxy.*config" >/dev/null 2>&1; then
      echo "privoxy 进程: 运行中"
    else
      echo "privoxy 进程: 未运行"
    fi
    if command -v sudo >/dev/null 2>&1 && sudo test -r "${PRIVOXY_CONFIG}"; then
      echo "privoxy 配置: ${PRIVOXY_CONFIG}"
      local listen_line
      local forward_line
      listen_line="$(sudo grep -E "^[[:space:]]*listen-address[[:space:]]+" "${PRIVOXY_CONFIG}" | head -n 1 || true)"
      forward_line="$(sudo grep -E "^[[:space:]]*forward-socks5t[[:space:]]+/" "${PRIVOXY_CONFIG}" | head -n 1 || true)"
      if [[ -n "${listen_line}" ]]; then
        echo "listen-address: ${listen_line}"
      else
        echo "listen-address: 未找到（建议: listen-address  ${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}）"
      fi
      if [[ -n "${forward_line}" ]]; then
        echo "forward-socks5t: ${forward_line}"
      else
        echo "forward-socks5t: 未找到（建议: forward-socks5t / ${LOCAL_HOST}:${LOCAL_PORT} .）"
      fi
    else
      echo "privoxy 配置: 不可读 (${PRIVOXY_CONFIG})"
    fi
    rc=1
  fi

  return "${rc}"
}

print_env() {
  local mode="${1:-set}"
  if [[ "${mode}" == "unset" ]]; then
    cat <<'EOF'
unset HTTP_PROXY
unset HTTPS_PROXY
unset ALL_PROXY
unset http_proxy
unset https_proxy
unset all_proxy
EOF
    return 0
  fi

  local http_proxy_url
  if pgrep -f "privoxy.*config" >/dev/null 2>&1; then
    http_proxy_url="http://${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
  else
    http_proxy_url="socks5h://${LOCAL_HOST}:${LOCAL_PORT}"
  fi
  local all_proxy_url="socks5h://${LOCAL_HOST}:${LOCAL_PORT}"

  cat <<EOF
export HTTP_PROXY='${http_proxy_url}'
export HTTPS_PROXY='${http_proxy_url}'
export ALL_PROXY='${all_proxy_url}'
export http_proxy="\${HTTP_PROXY}"
export https_proxy="\${HTTPS_PROXY}"
export all_proxy="\${ALL_PROXY}"
EOF
}

check_connectivity() {
  local rc=0
  local test_host="google.com"
  local dns_ok=0
  local tcp_ok=0
  local proxy_ok=0

  echo "检查目标: ${test_host}"
  echo

  echo "== DNS 解析检查 =="
  if command -v getent >/dev/null 2>&1; then
    if getent ahosts "${test_host}" >/dev/null 2>&1; then
      echo "DNS 解析通过"
      dns_ok=1
    else
      echo "DNS 解析失败"
      rc=1
    fi
  elif command -v nslookup >/dev/null 2>&1; then
    if nslookup "${test_host}" >/dev/null 2>&1; then
      echo "DNS 解析通过"
      dns_ok=1
    else
      echo "DNS 解析失败"
      rc=1
    fi
  else
    echo "未找到 getent/nslookup，跳过 DNS 检查"
  fi

  echo
  echo "== TCP 直连检查 (${test_host}:443) =="
  if command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
    if timeout 5 bash -c "exec 3<>/dev/tcp/${test_host}/443" >/dev/null 2>&1; then
      echo "TCP 直连通过"
      tcp_ok=1
    else
      echo "TCP 直连失败（可能被网络策略拦截）"
      rc=1
    fi
  else
    echo "未找到 timeout/bash，跳过 TCP 检查"
  fi

  echo
  echo "== HTTP 代理链路检查 =="
  if test_proxy; then
    echo "代理链路检查通过"
    proxy_ok=1
  else
    echo "代理链路检查失败"
    rc=1
  fi

  echo
  echo "== 最终结论 =="
  if [[ "${proxy_ok}" == "1" && "${tcp_ok}" == "0" ]]; then
    echo "直连受限，代理可用。建议日常使用代理访问外网，不要以 ping 作为代理可用性判断。"
  elif [[ "${proxy_ok}" == "1" && "${tcp_ok}" == "1" ]]; then
    echo "直连与代理都可用。可按需选择直连或代理。"
  elif [[ "${proxy_ok}" == "0" && "${dns_ok}" == "0" ]]; then
    echo "DNS 与代理都异常。建议先修复 DNS，再检查代理配置。"
  elif [[ "${proxy_ok}" == "0" ]]; then
    echo "直连可能可用，但代理链路异常。建议执行 ./proxy.sh up && ./proxy.sh test 进一步排查。"
  else
    echo "网络状态部分受限，请根据上方各项结果逐项排查。"
  fi

  return "${rc}"
}

tun_status() {
  local running=0
  echo "== sing-box TUN 进程状态 =="
  if pgrep -f "sing-box.*${SINGBOX_CONFIG}" >/dev/null 2>&1; then
    echo "运行中"
    running=1
  else
    echo "未运行"
  fi

  echo
  echo "== TUN 网卡状态 (${TUN_INTERFACE}) =="
  if command -v ip >/dev/null 2>&1 && ip link show "${TUN_INTERFACE}" >/dev/null 2>&1; then
    echo "网卡存在"
  else
    echo "网卡不存在"
  fi

  echo
  echo "== TUN 日志 =="
  if [[ -f "${SINGBOX_LOG_FILE}" ]]; then
    if [[ "${running}" == "1" ]]; then
      tail_output="$(awk 'NR>20{buf[NR%20]=$0;next}{buf[NR%20]=$0} END{start=(NR>20?NR-19:1); for(i=start;i<=NR;i++) print buf[i%20]}' "${SINGBOX_LOG_FILE}" 2>/dev/null || true)"
      if [[ -n "${tail_output}" ]]; then
        echo "${tail_output}"
      else
        echo "(日志为空)"
      fi
    else
      echo "TUN 未运行，最近日志文件: ${SINGBOX_LOG_FILE}"
    fi
  else
    echo "未找到日志文件: ${SINGBOX_LOG_FILE}"
  fi
}

tun_test() {
  local rc=0
  echo "== TUN 连通性测试 =="
  if ping -c 1 -W 3 google.com >/dev/null 2>&1; then
    echo "ping google.com: 通过"
  else
    echo "ping google.com: 失败"
    rc=1
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl --silent --show-error --fail --max-time 10 https://www.google.com >/dev/null; then
      echo "curl https://www.google.com: 通过"
    else
      echo "curl https://www.google.com: 失败"
      rc=1
    fi
  else
    echo "未找到 curl，跳过 HTTP 测试"
  fi
  return "${rc}"
}

install_cmd() {
  local bin_dir="${HOME}/.local/bin"
  local target="${bin_dir}/proxy"

  mkdir -p "${bin_dir}"
  ln -sfn "${BASE_DIR}/proxy.sh" "${target}"
  chmod +x "${BASE_DIR}/proxy.sh" "${BASE_DIR}/proxy-yiyun.sh" "${BASE_DIR}/proxy-off.sh" "${BASE_DIR}/proxy-tun-up.sh" "${BASE_DIR}/proxy-tun-down.sh"

  echo "已安装: ${target} -> ${BASE_DIR}/proxy.sh"
  if [[ ":${PATH}:" != *":${bin_dir}:"* ]]; then
    echo "提示: 你的 PATH 中尚未包含 ${bin_dir}"
    echo "可执行: export PATH=\"${bin_dir}:\$PATH\""
  else
    echo "现在可直接使用: proxy up|down|restart|status"
  fi
}

uninstall_cmd() {
  local target="${HOME}/.local/bin/proxy"
  if [[ -L "${target}" || -f "${target}" ]]; then
    rm -f "${target}"
    echo "已卸载: ${target}"
  else
    echo "未发现已安装的 proxy 命令: ${target}"
  fi
}

cmd="${1:-}"

case "${cmd}" in
  up)
    exec bash "${UP_SCRIPT}"
    ;;
  down)
    exec bash "${DOWN_SCRIPT}"
    ;;
  restart)
    bash "${DOWN_SCRIPT}"
    exec bash "${UP_SCRIPT}"
    ;;
  status)
    status
    ;;
  test)
    test_proxy
    ;;
  check)
    check_connectivity
    ;;
  tun-up)
    exec bash "${TUN_UP_SCRIPT}"
    ;;
  tun-down)
    exec bash "${TUN_DOWN_SCRIPT}"
    ;;
  tun-restart)
    bash "${TUN_DOWN_SCRIPT}"
    exec bash "${TUN_UP_SCRIPT}"
    ;;
  tun-status)
    tun_status
    ;;
  tun-test)
    tun_test
    ;;
  env)
    if [[ "${2:-}" == "--unset" ]]; then
      print_env "unset"
    else
      print_env
    fi
    ;;
  install)
    install_cmd
    ;;
  uninstall)
    uninstall_cmd
    ;;
  *)
    usage
    exit 1
    ;;
esac

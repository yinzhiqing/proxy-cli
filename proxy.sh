#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
UP_SCRIPT="${BASE_DIR}/proxy-yiyun.sh"
DOWN_SCRIPT="${BASE_DIR}/proxy-off.sh"
LOCAL_PORT="${LOCAL_PORT:-1080}"

usage() {
  cat <<'EOF'
用法:
  ./proxy.sh up       启动代理
  ./proxy.sh down     关闭代理
  ./proxy.sh restart  重启代理
  ./proxy.sh status   查看代理状态
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

install_cmd() {
  local bin_dir="${HOME}/.local/bin"
  local target="${bin_dir}/proxy"

  mkdir -p "${bin_dir}"
  ln -sfn "${BASE_DIR}/proxy.sh" "${target}"
  chmod +x "${BASE_DIR}/proxy.sh" "${BASE_DIR}/proxy-yiyun.sh" "${BASE_DIR}/proxy-off.sh"

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

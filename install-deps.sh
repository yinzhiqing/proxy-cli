#!/usr/bin/env bash
# 初始化 net-proxy 运行环境所需系统依赖（shadowsocks-libev、privoxy、curl、python3 等）。
# 用法见: ./install-deps.sh --help

set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  ./install-deps.sh              安装常用依赖（含 SOCKS + HTTP 代理与连通性测试）
  ./install-deps.sh --minimal  仅安装 SOCKS 所需最小集合（不含 privoxy）
  ./install-deps.sh --with-tun   在上述基础上尝试安装 sing-box（TUN 全局代理）

说明:
  - 需要可用的 sudo（安装系统软件包）。
  - sing-box 在部分发行版无官方仓库包，安装失败时请参见 sing-box 文档手动安装。
EOF
}

MINIMAL=0
WITH_TUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --minimal)
      MINIMAL=1
      shift
      ;;
    --with-tun)
      WITH_TUN=1
      shift
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "请不要直接用 root 运行本脚本；请用普通用户执行，脚本会在需要时调用 sudo。" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "错误: 未找到 sudo。" >&2
  exit 1
fi

if ! sudo -n true 2>/dev/null; then
  echo "即将安装系统软件包，可能需要输入 sudo 密码。"
fi

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then
    echo apt
  elif command -v dnf >/dev/null 2>&1; then
    echo dnf
  elif command -v yum >/dev/null 2>&1; then
    echo yum
  elif command -v pacman >/dev/null 2>&1; then
    echo pacman
  elif command -v zypper >/dev/null 2>&1; then
    echo zypper
  elif command -v apk >/dev/null 2>&1; then
    echo apk
  else
    echo unknown
  fi
}

PM="$(detect_pm)"

run_install() {
  local pkgs=("$@")
  case "${PM}" in
    apt)
      sudo apt-get update
      sudo apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    dnf)
      sudo dnf install -y "${pkgs[@]}"
      ;;
    yum)
      sudo yum install -y "${pkgs[@]}"
      ;;
    pacman)
      sudo pacman -Sy --needed --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      sudo zypper install -y "${pkgs[@]}"
      ;;
    apk)
      sudo apk add "${pkgs[@]}"
      ;;
    *)
      echo "错误: 未识别的包管理器，无法自动安装。" >&2
      echo "请根据 README.md「依赖要求」一节手动安装对应软件包。" >&2
      exit 1
      ;;
  esac
}

install_sing_box() {
  echo "== 尝试安装 sing-box（TUN）=="
  case "${PM}" in
    apt | dnf | yum | pacman | zypper | apk)
      run_install sing-box || true
      ;;
    *)
      ;;
  esac

  if command -v sing-box >/dev/null 2>&1; then
    echo "sing-box 已通过包管理器安装。"
    return 0
  fi

  echo "警告: 未能通过当前环境的包管理器安装 sing-box。" >&2
  echo "请参考官方文档手动安装: https://sing-box.sagernet.org/installation/package-manager/" >&2
  return 1
}

echo "== net-proxy 依赖安装（包管理器: ${PM}）=="

CORE_PKGS=()
HTTP_PKGS=()

case "${PM}" in
  apt)
    CORE_PKGS=(shadowsocks-libev curl python3 iproute2)
    HTTP_PKGS=(privoxy)
    ;;
  dnf | yum)
    CORE_PKGS=(shadowsocks-libev curl python3 iproute)
    HTTP_PKGS=(privoxy)
    ;;
  pacman)
    CORE_PKGS=(shadowsocks-libev curl python iproute2)
    HTTP_PKGS=(privoxy)
    ;;
  zypper)
    CORE_PKGS=(shadowsocks-libev curl python3 iproute2)
    HTTP_PKGS=(privoxy)
    ;;
  apk)
    CORE_PKGS=(shadowsocks-libev curl python3 iproute2)
    HTTP_PKGS=(privoxy)
    ;;
  *)
    echo "错误: 不支持的包管理器 '${PM}'，无法列出依赖软件包。" >&2
    exit 1
    ;;
esac

TO_INSTALL=("${CORE_PKGS[@]}")
if [[ "${MINIMAL}" -eq 0 ]]; then
  TO_INSTALL+=("${HTTP_PKGS[@]}")
fi

run_install "${TO_INSTALL[@]}"

echo
echo "已请求安装: ${TO_INSTALL[*]}"

if [[ "${WITH_TUN}" -eq 1 ]]; then
  echo
  install_sing_box || true
fi

echo
echo "依赖安装步骤已完成。建议执行:"
echo "  chmod +x proxy.sh proxy-yiyun.sh proxy-off.sh proxy-tun-up.sh proxy-tun-down.sh"
echo "并按 README 配置 client.json。"

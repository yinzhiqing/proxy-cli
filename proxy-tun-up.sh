#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/shadowsocks-libev/client.json}"
SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/sing-box/config-net-proxy.json}"
SINGBOX_PID_FILE="${SINGBOX_PID_FILE:-/tmp/sing-box-tun.pid}"
SINGBOX_LOG_FILE="${SINGBOX_LOG_FILE:-/tmp/sing-box-tun.log}"
TUN_INTERFACE="${TUN_INTERFACE:-sb-tun}"
TUN_INET4_ADDRESS="${TUN_INET4_ADDRESS:-172.19.0.1/30}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 未找到命令 '$1'" >&2
    exit 1
  fi
}

require_cmd sudo
require_cmd python3

if ! command -v sing-box >/dev/null 2>&1; then
  echo "错误: 未找到命令 'sing-box'，请先安装。"
  exit 1
fi

if ! sudo test -r "${CONFIG_FILE}"; then
  echo "错误: 无法读取 Shadowsocks 配置: ${CONFIG_FILE}"
  exit 1
fi

echo "生成 sing-box TUN 配置: ${SINGBOX_CONFIG}"
sudo mkdir -p "$(dirname "${SINGBOX_CONFIG}")"
sudo python3 - "${CONFIG_FILE}" "${SINGBOX_CONFIG}" "${TUN_INTERFACE}" "${TUN_INET4_ADDRESS}" <<'PY'
import ipaddress
import json
import socket
import sys

config_file, out_file, tun_interface, tun_inet4 = sys.argv[1:]
with open(config_file, "r", encoding="utf-8") as f:
    ss = json.load(f)

required = ["server", "server_port", "method", "password"]
missing = [k for k in required if k not in ss]
if missing:
    raise SystemExit(f"Shadowsocks 配置缺少字段: {', '.join(missing)}")

server = str(ss["server"])
server_ip_cidrs = []
server_is_ip = False

try:
    parsed_ip = ipaddress.ip_address(server)
    server_is_ip = True
    suffix = "32" if parsed_ip.version == 4 else "128"
    server_ip_cidrs.append(f"{parsed_ip}/{suffix}")
except ValueError:
    try:
        infos = socket.getaddrinfo(server, ss["server_port"], proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        infos = []

    seen = set()
    for info in infos:
        addr = info[4][0]
        if addr in seen:
            continue
        seen.add(addr)
        parsed_ip = ipaddress.ip_address(addr)
        suffix = "32" if parsed_ip.version == 4 else "128"
        server_ip_cidrs.append(f"{parsed_ip}/{suffix}")

route_rules = [
    {"action": "sniff"},
    {"protocol": ["dns"], "action": "hijack-dns"},
]

if not server_is_ip:
    route_rules.append(
        {
            "domain": [server],
            "action": "route",
            "outbound": "direct",
        }
    )

if server_ip_cidrs:
    route_rules.append(
        {
            "ip_cidr": server_ip_cidrs,
            "action": "route",
            "outbound": "direct",
        }
    )

route_rules.append(
    {
        "ip_is_private": True,
        "action": "route",
        "outbound": "direct",
    }
)

out = {
    "log": {"level": "info"},
    "dns": {
        "servers": [
            {
                "type": "https",
                "tag": "remote-dns",
                "server": "1.1.1.1",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "ss-out",
            }
        ],
        "final": "remote-dns",
        "strategy": "ipv4_only",
    },
    "inbounds": [
        {
            "type": "tun",
            "interface_name": tun_interface,
            "address": [tun_inet4],
            "stack": "gvisor",
            "auto_route": True,
            "strict_route": True,
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct",
        },
        {
            "type": "shadowsocks",
            "tag": "ss-out",
            "server": ss["server"],
            "server_port": ss["server_port"],
            "method": ss["method"],
            "password": ss["password"],
        }
    ],
    "route": {
        "auto_detect_interface": True,
        "rules": route_rules,
        "final": "ss-out",
    },
}

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY

if [[ -f "${SINGBOX_PID_FILE}" ]]; then
  old_pid="$(sudo cat "${SINGBOX_PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && ps -p "${old_pid}" >/dev/null 2>&1; then
    echo "检测到旧的 sing-box 进程，正在停止..."
    sudo kill "${old_pid}" || true
    sleep 1
  fi
  sudo rm -f "${SINGBOX_PID_FILE}" || true
fi

if pgrep -f "sing-box.*${SINGBOX_CONFIG}" >/dev/null 2>&1; then
  sudo pkill -f "sing-box.*${SINGBOX_CONFIG}" || true
  sleep 1
fi

echo "启动 sing-box TUN..."
sudo bash -c "nohup sing-box run -c '${SINGBOX_CONFIG}' >'${SINGBOX_LOG_FILE}' 2>&1 & echo \$! > '${SINGBOX_PID_FILE}'"
sleep 2

new_pid="$(sudo cat "${SINGBOX_PID_FILE}" 2>/dev/null || true)"
if [[ -z "${new_pid}" ]] || ! ps -p "${new_pid}" >/dev/null 2>&1; then
  echo "错误: sing-box 启动失败，请查看日志: ${SINGBOX_LOG_FILE}" >&2
  exit 1
fi

echo "TUN 代理已启动 (pid=${new_pid})"
echo "提示: 使用 ./proxy.sh tun-test 验证 ping/curl 连通性"

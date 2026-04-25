# net-proxy

一个基于 `shadowsocks-libev` 的 Linux 代理管理脚本集合，用于一键启动/关闭本地 SOCKS5 代理，并可选启动 `privoxy` 提供本地 HTTP 代理，同时支持自动同步 GNOME 系统代理设置。

## 功能概览

- 统一入口脚本：`proxy.sh`
- 支持命令：`up` / `down` / `restart` / `status`
- 支持测试：`test` 一键验证 SOCKS5/HTTP 代理连通性
- 可安装为全局命令：`proxy install` / `proxy uninstall`
- 启动时自动处理残留 `ss-local` 进程，避免重复占用端口
- 可选自动拉起 `privoxy`，提供 `http://127.0.0.1:8118` 本地 HTTP 代理
- 可选自动设置/关闭 GNOME 系统代理（`gsettings`）

## 文件结构

- `proxy.sh`：主入口，负责命令分发与安装卸载
- `proxy-yiyun.sh`：启动代理，拉起 `ss-local` 并尝试设置系统代理
- `proxy-off.sh`：关闭代理，停止 `ss-local` 并尝试关闭系统代理
- `client.example.json`：脱敏模板配置，可复制为本地真实配置
- `client.json`：本地真实配置（已在 `.gitignore` 中忽略）

## 依赖要求

- Bash（建议 4+）
- `sudo`
- `ss-local`（由 `shadowsocks-libev` 提供）
- 可选：`privoxy`（将 HTTP 代理流量转发到本地 SOCKS5）
- 可选：`gsettings`（GNOME 环境下自动配置系统代理）

安装 `shadowsocks-libev` 示例：

```bash
# Debian / Ubuntu
sudo apt install shadowsocks-libev

# Fedora / RHEL
sudo dnf install shadowsocks-libev

# Arch Linux
sudo pacman -S shadowsocks-libev
```

安装 `privoxy` 示例（用于 HTTP 代理）：

```bash
# Debian / Ubuntu
sudo apt install privoxy

# Fedora / RHEL
sudo dnf install privoxy

# Arch Linux
sudo pacman -S privoxy
```

并在 `/etc/privoxy/config` 中确认类似配置存在：

```conf
listen-address  127.0.0.1:8118
forward-socks5t / 127.0.0.1:1080 .
```

## 快速开始

1) 给脚本执行权限（首次）：

```bash
chmod +x proxy.sh proxy-yiyun.sh proxy-off.sh
```

2) 准备配置文件（默认读取 `/etc/shadowsocks-libev/client.json`）：

```bash
sudo mkdir -p /etc/shadowsocks-libev
cp client.example.json client.json
# 编辑 client.json，填入你的 server/password 等真实参数
sudo cp client.json /etc/shadowsocks-libev/client.json
sudo chmod 600 /etc/shadowsocks-libev/client.json
```

3) 启动/关闭/查看状态：

```bash
./proxy.sh up
./proxy.sh status
./proxy.sh down
```

4) 安装为全局命令（可选）：

```bash
./proxy.sh install
proxy up
proxy status
proxy down
```

> 若提示找不到 `proxy`，请把 `~/.local/bin` 加入 `PATH`。

## 命令说明

```bash
./proxy.sh up        # 启动代理
./proxy.sh down      # 关闭代理
./proxy.sh restart   # 重启代理
./proxy.sh status    # 查看进程和 GNOME 代理状态
./proxy.sh test      # 测试 SOCKS5/HTTP 代理连通性（失败时自动诊断）
./proxy.sh check     # 检查 DNS/TCP/HTTP 三层连通性，并输出最终结论
./proxy.sh tun-up    # 启动 TUN 全局代理（sing-box）
./proxy.sh tun-down  # 关闭 TUN 全局代理（sing-box）
./proxy.sh tun-restart # 重启 TUN 全局代理（sing-box）
./proxy.sh tun-status # 查看 TUN 代理状态
./proxy.sh tun-test  # 测试 TUN 连通性（含 ping）
./proxy.sh env       # 输出当前建议的代理环境变量（用于 eval）
./proxy.sh env --unset # 输出清理代理环境变量命令（用于 eval）
./proxy.sh install   # 安装 proxy 命令到 ~/.local/bin/proxy
./proxy.sh uninstall # 卸载 ~/.local/bin/proxy
```

示例（将当前 shell 设置为走代理）：

```bash
eval "$(./proxy.sh env)"
```

示例（清理当前 shell 的代理变量）：

```bash
eval "$(./proxy.sh env --unset)"
```

## TUN 全局代理（可让 ping 走代理）

依赖：

- `sing-box`
- `sudo`
- `python3`

启动/关闭：

```bash
./proxy.sh tun-up
./proxy.sh tun-status
./proxy.sh tun-test
./proxy.sh tun-down
```

说明：

- `tun-up` 会读取 `CONFIG_FILE`（默认 `/etc/shadowsocks-libev/client.json`）中的服务端参数自动生成 sing-box 配置。
- 默认生成到 `/etc/sing-box/config-net-proxy.json`，并创建 `sb-tun` 网卡。
- 默认日志文件：`/tmp/sing-box-tun.log`。

## 环境变量

可通过环境变量覆盖默认行为：

- `CONFIG_FILE`：配置文件路径（默认 `/etc/shadowsocks-libev/client.json`）
- `LOCAL_HOST`：本地绑定地址（默认 `127.0.0.1`）
- `LOCAL_PORT`：本地监听端口（默认 `1080`）
- `AUTO_SYSTEM_PROXY`：是否自动配置系统代理（`1` 开启，`0` 关闭，默认 `1`）
- `PID_FILE`：停止脚本使用的 PID 文件路径（默认 `/tmp/ss-local.pid`）
- `ENABLE_HTTP_PROXY`：是否自动启动/关闭 HTTP 代理（`1` 开启，`0` 关闭，默认 `1`）
- `HTTP_PROXY_HOST`：HTTP 代理监听地址（默认 `127.0.0.1`，与 privoxy 配置一致）
- `HTTP_PROXY_PORT`：HTTP 代理监听端口（默认 `8118`，与 privoxy 配置一致）
- `PRIVOXY_CONFIG`：privoxy 配置文件路径（默认 `/etc/privoxy/config`）
- `PRIVOXY_PID_FILE`：privoxy PID 文件路径（默认 `/tmp/privoxy.pid`）
- `PROXY_TEST_URL`：`proxy test` 使用的测试 URL（默认 `https://www.gstatic.com/generate_204`）
- `SINGBOX_CONFIG`：TUN 模式 sing-box 配置路径（默认 `/etc/sing-box/config-net-proxy.json`）
- `SINGBOX_PID_FILE`：TUN 模式 PID 文件（默认 `/tmp/sing-box-tun.pid`）
- `SINGBOX_LOG_FILE`：TUN 模式日志文件（默认 `/tmp/sing-box-tun.log`）
- `TUN_INTERFACE`：TUN 网卡名（默认 `sb-tun`）
- `TUN_INET4_ADDRESS`：TUN 网段地址（默认 `172.19.0.1/30`）

示例：

```bash
CONFIG_FILE="$HOME/.config/shadowsocks/client.json" \
LOCAL_PORT=1090 \
HTTP_PROXY_PORT=8119 \
AUTO_SYSTEM_PROXY=0 \
./proxy.sh up
```

启动后：

- SOCKS5: `socks5h://127.0.0.1:1080`
- HTTP: `http://127.0.0.1:8118`（启用 `ENABLE_HTTP_PROXY=1` 且 `privoxy` 可用时）

`./proxy.sh up` 在启用 HTTP 代理时会检查 `privoxy` 配置中是否包含：

- `listen-address 127.0.0.1:8118`（端口按 `HTTP_PROXY_PORT` 可变）
- `forward-socks5t / 127.0.0.1:1080 .`（目标按 `LOCAL_HOST/LOCAL_PORT` 可变）

若脚本对 `PRIVOXY_CONFIG` 指向的配置文件具有写权限，会自动写入一个受控配置块来补齐缺失项；若配置文件不可写或 `privoxy` 启动失败，脚本会回退为仅设置 SOCKS5 环境变量（`HTTP_PROXY/HTTPS_PROXY` 指向 `socks5h://...`）。

## 配置文件示例

建议先复制模板：

```bash
cp client.example.json client.json
```

`client.json` 至少应包含以下字段（示例值请替换）：

```json
{
  "server": "your.server.ip",
  "server_port": 8388,
  "password": "your-password",
  "method": "aes-256-gcm",
  "local_address": "127.0.0.1",
  "local_port": 1080,
  "mode": "tcp_and_udp",
  "timeout": 86400
}
```

## 常见问题

- 启动失败提示找不到 `ss-local`
  - 先安装 `shadowsocks-libev`，再执行 `ss-local -h` 验证命令可用。
- 启动失败提示无法读取配置文件
  - 检查 `CONFIG_FILE` 路径是否正确，确认文件权限可读。
- `status` 显示系统代理不可写
  - 当前会话可能不是 GNOME 图形环境，或 `gsettings` 不可用；可仅使用命令行代理。
- 网络仍不通
  - 检查服务端参数（`server`、`server_port`、`method`、`password`）是否与服务端一致，并确认本地端口未冲突。

## 安全建议

- 不要在仓库中提交真实 `server`/`password` 等敏感信息。
- 推荐把真实凭据仅保存在本地 `client.json`，模板使用 `client.example.json`。
- 如敏感信息曾提交到历史，请尽快轮换密码并清理历史。
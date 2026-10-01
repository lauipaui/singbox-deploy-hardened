# singbox-deploy-hardened

**中文** | [English](README.en.md)

一个面向 Linux VPS 的交互式 sing-box 部署脚本。脚本会检测系统、安装必要依赖、生成随机凭据和配置，并创建服务与 `sb` 管理命令。

## 支持的平台

- Debian / Ubuntu
- Alpine Linux
- CentOS / RHEL / Fedora（使用 yum）

需要以 root 身份运行，并要求服务器能够访问软件包仓库及 sing-box 官方安装源。

## 支持的协议

安装时可选择一个或多个协议：

- Shadowsocks（2022 或 AES-128-GCM）
- Hysteria2
- TUIC
- VLESS Reality
- AnyTLS Reality

## 使用方式

先查看脚本内容，再执行：

```bash
git clone https://github.com/lauipaui/singbox-deploy-hardened.git
cd singbox-deploy-hardened
less install-singbox-yyds.sh
sudo bash install-singbox-yyds.sh
```

### 一键安装

公开仓库可以直接执行：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lauipaui/singbox-deploy-hardened/main/install.sh)"
```

如果当前已经是 root 用户，也可以省略 `sudo`：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/lauipaui/singbox-deploy-hardened/main/install.sh)"
```

也可以使用仓库提供的一键入口：

```bash
sudo bash install.sh
```

`install.sh`（入口版本 1.2.0）会从本仓库 `main` 下载主脚本至私有临时目录，验证**入口内固定的 SHA-256**并执行 Bash 语法检查后才运行；并不调用同目录文件。若要安装已审阅的本地快照，请直接执行 `bash install-singbox-yyds.sh`。脚本不内置令牌或密码。

安装过程中会依次询问节点名称、协议、端口及 Reality 的连接 IP/SNI。未手动指定的端口、密码和 UUID 会随机生成。安装完成后，脚本会显示客户端 URI。

不要把访问令牌、密码或私钥写入脚本、README 或命令历史。

## 管理命令

安装完成后执行：

```bash
sudo sb
```

管理菜单支持查看 URI、查看或编辑配置、启动/停止/重启/查看状态、更新 sing-box、重置各协议端口、生成线路机中转配置以及卸载。

配置和凭据主要位于：

- `/etc/sing-box/config.json`
- `/etc/sing-box/.config_cache`
- `/etc/sing-box/.protocols`
- `/etc/sing-box/certs/`（启用 Hysteria2 或 TUIC 时）
- `/usr/local/bin/sb`

脚本设计中 Debian、Ubuntu、CentOS、RHEL 和 Fedora 使用 systemd；Alpine 使用 OpenRC。这是代码支持范围，不是本次对全部发行版的实机验收。日志分别位于 systemd journal 或 `/var/log/sing-box.log`、`/var/log/sing-box.err`。

## 本次审计加固

- 默认使用 `umask 077`，新生成的敏感文件仅允许所有者访问。
- 对配置、缓存、协议状态、管理脚本和中转脚本设置更严格的文件权限。
- 使用 `mktemp` 创建临时配置和中转脚本，降低临时文件名冲突及抢占风险。
- 对公网 IP/主机名、Reality SNI 和端口进行校验；缓存元数据使用 JSON，管理器不把旧缓存当 shell 源码执行。
- Alpine 软件源改用 HTTPS。
- Reality 可默认启用本机 HAProxy SNI 白名单：未通过 Reality 鉴权的 TLS 连接只有在 SNI 与安装时填写的伪装域名完全一致时才会被转发，避免 Cloudflare 等共享 CDN 被当作任意 TCP 中转消耗 VPS 流量。
- Reality 增加 `max_time_difference: 1m`，降低异常握手和重放窗口。
- Alpine 优先使用当前发行版的 `community` 仓库，同时提供 `edge/community` 和官方安装器回退；OpenRC 服务改用 `supervise-daemon` 单一监管方式。
- 卸载时按系统实际可用的 `apt-get`、`dnf` 或 `yum` 选择包管理器。

## 安全注意事项

这是一个会以 root 身份修改系统的部署脚本。使用前应审阅脚本内容，并在防火墙中只开放实际启用的端口。

更新功能会从 `https://sing-box.app/install.sh` 获取上游安装脚本；生产环境建议在变更前固定版本并审阅下载内容。Hysteria2/TUIC 的客户端 URI 目前包含 `insecure=1`，因为服务端使用自签名证书；如果客户端环境支持，建议改用受信任证书并移除该选项。

当启用 Reality 防偷流量时，脚本会安装独立的 `sing-box-reality-guard` 服务并仅监听 `127.0.0.1`，不会新增公网端口。更换 Reality SNI 时必须同步更新 `/etc/sing-box/reality-guard.cfg`，否则伪装握手会被白名单拒绝。

卸载操作会删除 `/etc/sing-box`、服务文件、日志、管理命令及 `/usr/bin/sing-box`，请先备份需要保留的配置和凭据。

## 文件、检查与测试

| 文件 | 职责 |
| --- | --- |
| [`install.sh`](install.sh) | 下载、固定哈希校验和启动入口 |
| [`install-singbox-yyds.sh`](install-singbox-yyds.sh) | 交互安装器及生成的管理/中转脚本 |
| [`test-regression.cjs`](test-regression.cjs) | 配置生成、注入拒绝、URI 与本机回环协议测试 |

```sh
# 不安装，仅检查本地语法与入口版本
bash -n install.sh
bash -n install-singbox-yyds.sh
bash install.sh --version
# 会联网下载并校验主脚本，但不执行安装
bash install.sh --check
```

完整回归需要 Node.js、Bash、jq、OpenSSL、curl 和兼容的 sing-box 二进制。测试默认路径沿用原 Windows 工作区；其他环境通过 `TEST_BASH`、`TEST_JQ_DIR`、`TEST_SINGBOX` 显式覆盖。Linux 示例：

```sh
TEST_BASH=/bin/bash TEST_JQ_DIR=/usr/bin TEST_SINGBOX=/usr/bin/sing-box \
  node test-regression.cjs
```

测试使用临时目录和本机回环连接，但会启动实际 sing-box 子进程；不是简单的文本检查。本次只改 README，没有安装、升级核心或重新运行完整协议验收。

## 备份、回滚与常见问题

- 重装已有环境前，脚本把 `config.json`、`.config_cache`、`.protocols`、`.reality_pub`、`.reality_sid` 中已存在的文件备份到 `/etc/sing-box/backup.*`，权限收紧。**该备份仅在 `/etc/sing-box/config.json` 存在时才会创建**；若之前安装中断/损坏，`config.json` 缺失但状态文件仍在，重跑会直接覆盖 `.config_cache`、`.protocols` 和 Reality 元数据而不备份，此时请先手动复制整个 `/etc/sing-box`。这不是整机快照，也不覆盖所有证书、服务、二进制和 HAProxy 配置；请额外保存需要恢复的项目和版本。
- 端口重置等配置替换路径会先校验候选、保存 `rollback.*.json`，新配置启动失败时尝试恢复旧配置。手工编辑、外部更新和完整卸载不能依赖这一局部回滚。
- 生产回滚前保持 SSH 会话/带外入口：恢复受保护的备份和兼容核心，`sing-box check -c /etc/sing-box/config.json` 成功后重启原服务，再检查日志及真实客户端。
- 固定哈希失败：可能是 GitHub 缓存或入口与主脚本不同步，重新获取同一受信任版本并核对；**不要删掉校验绕过失败**。
- 服务启动失败：先看配置校验及日志，不用重新生成全部凭据掩盖问题。
- 生成的客户端链接含凭据，不要贴到公开 Issue、日志或截图；中转脚本同样按敏感资料保护。

## 许可证与来源

本仓库用于保存经过审计和加固的部署脚本，没有独立 `LICENSE`；不因此授予任意再许可权。保留代码中的来源信息，使用和再发行前确认 sing-box、发行版软件包及相关组件的许可和合规要求。

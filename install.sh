#!/usr/bin/env bash
set -euo pipefail

# One-click entry point for the audited installer.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/install-singbox-yyds.sh"

if [[ "$(id -u)" != "0" ]]; then
    echo "请使用 root 权限运行：sudo bash install.sh" >&2
    exit 1
fi

if [[ ! -f "$INSTALLER" ]]; then
    echo "未找到加固安装脚本：$INSTALLER" >&2
    echo "请确认 install.sh 与 install-singbox-yyds.sh 位于同一目录。" >&2
    exit 1
fi

exec bash "$INSTALLER" "$@"

#!/usr/bin/env bash
# singbox-deploy-hardened bootstrap v1.1.0
# Compatible with: bash -c "$(curl -fsSL .../install.sh)"
set -euo pipefail
bootstrap() (
    set -euo pipefail
    mode="install"
    case "${1:-}" in
        --version) printf '%s\n' 'singbox-deploy-hardened 1.1.0'; exit 0 ;;
        --check) mode="check"; shift ;;
        "") ;;
        *) printf '%s\n' '用法: bash install.sh [--check|--version]' >&2; exit 2 ;;
    esac
    if [ "$mode" = install ] && [ "$(id -u)" != 0 ]; then
        printf '%s\n' '请以 root 运行或使用 sudo bash。' >&2
        exit 1
    fi
    command -v curl >/dev/null || { echo '请先安装 curl' >&2; exit 1; }
    command -v sha256sum >/dev/null || { echo '请先安装 sha256sum（coreutils）' >&2; exit 1; }
    umask 077
    task_dir="$(mktemp -d "${TMPDIR:-/tmp}/singbox-install.XXXXXXXX")"
    trap 'rm -rf -- "$task_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    installer="$task_dir/install-singbox-yyds.sh"
    curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 10 --max-time 120 --retry 2 \
        'https://raw.githubusercontent.com/lauipaui/singbox-deploy-hardened/main/install-singbox-yyds.sh' \
        -o "$installer"
    [ -s "$installer" ] || { echo '下载内容为空' >&2; exit 1; }
    printf '%s  %s\n' '708e2e706d0353106b78dc4b0cd09d9f58cf335982139854714319b0c9812788' "$installer" | sha256sum -c - >/dev/null ||
        { echo '脚本校验失败（可能是缓存版本不同步），请稍后重试' >&2; exit 1; }
    bash -n "$installer"
    if [ "$mode" = check ]; then
        echo '下载、SHA-256 校验和 Bash 语法检查通过（尚未安装）。'
        exit 0
    fi
    # Keep stdin attached to the terminal for the interactive main installer.
    bash "$installer" "$@"
)
bootstrap "$@"

#!/usr/bin/env bash
set -euo pipefail

# Create newly generated credentials and config files as owner-only by default.
umask 077

# Shared validation; normalize ports before using them as JSON or sed input.
validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || { err "端口必须是 1-65535 的整数"; return 1; }
    (( 10#$value >= 1 && 10#$value <= 65535 )) || { err "端口超出范围"; return 1; }
}
validate_host() {
    [[ -n "$1" && "$1" != *[!A-Za-z0-9.:%_-]* ]] ||
        { err "IP/域名包含非法字符"; return 1; }
}
install_upstream() {
    local installer status=0
    installer="$(mktemp /tmp/singbox-upstream.XXXXXX.sh)" || return 1
    if curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 10 --max-time 120 \
        --retry 2 -o "$installer" https://sing-box.app/install.sh &&
        [ -s "$installer" ] && bash -n "$installer"; then
        bash "$installer" || status=$?
    else
        err "上游安装脚本下载或语法检查失败"
        status=1
    fi
    rm -f -- "$installer"
    return "$status"
}

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

if [ -f /etc/sing-box/config.json ]; then
    read -r -p "已有配置，继续会替换协议和凭据（将备份），确认？(y/N): " overwrite
    [[ "$overwrite" =~ ^[Yy]$ ]] || exit 0
fi
mkdir -p /etc/sing-box
chmod 700 /etc/sing-box
if [ -f /etc/sing-box/config.json ]; then
    backup_dir="$(mktemp -d /etc/sing-box/backup.XXXXXX)"
    for saved in config.json .config_cache .protocols .reality_pub .reality_sid; do
        [ ! -f "/etc/sing-box/$saved" ] || cp -p "/etc/sing-box/$saved" "$backup_dir/"
    done
    chmod -R go-rwx "$backup_dir"
    info "原配置已备份到 $backup_dir"
fi

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认议名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    
    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done
    
    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi
    
    # 保存协议选择到文件（确保持久化）
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF
    
    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    
    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

# 创建配置目录
mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi
    
    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice
    
    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *) 
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac
    
    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
    # 也设默认，方便后续统一处理（若未选 reality，也写入缓存以便 sb 读取）
    REALITY_SNI="addons.mozilla.org"
fi

# Only allow host/SNI characters before values are persisted and later sourced by sb.
if [[ "$CUSTOM_IP" =~ [^A-Za-z0-9.:%_-] ]]; then
    err "连接 IP/DDNS 只允许字母、数字、点、冒号、百分号、下划线和连字符"
    exit 1
fi
if [[ "$REALITY_SNI" =~ [^A-Za-z0-9.-] ]]; then
    err "Reality SNI 只允许字母、数字、点和连字符"
    exit 1
fi

# Metadata is persisted as JSON only after configuration validation.

# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."
    
    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi
    
    if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
        PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
    else
        read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
        PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    fi

    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)

    info "AnyTLS Reality 端口: $PORT_ANYTLS"
    info "AnyTLS Reality 用户名: $ANYTLS_USER"
    info "AnyTLS Reality 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

declare -A used_ports=()
for protocol in SS HY2 TUIC REALITY ANYTLS; do
    flag="ENABLE_$protocol"
    if [ "${!flag}" = true ]; then
        variable="PORT_$protocol"
        validate_port "${!variable}" || exit 1
        port="$((10#${!variable}))"
        [ -z "${used_ports[$port]:-}" ] || { err "选择的协议端口重复: $port"; exit 1; }
        used_ports[$port]=1
        printf -v "$variable" '%s' "$port"
    fi
done

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            install_upstream || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    # Persist public metadata only after the new configuration passes validation.
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi
    
    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

secure_sensitive_files() {
    chmod 700 /etc/sing-box 2>/dev/null || true
    chmod 600 \
        /etc/sing-box/config.json \
        /etc/sing-box/.config_cache \
        /etc/sing-box/.protocols \
        /etc/sing-box/.reality_pub \
        /etc/sing-box/.reality_sid \
        /etc/sing-box/uris.txt \
        /etc/sing-box/certs/privkey.pem 2>/dev/null || true
}

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local target_path="$CONFIG_PATH"
    local CONFIG_PATH
    CONFIG_PATH="$(mktemp /etc/sing-box/config.XXXXXX.json)"
    local TEMP_INBOUNDS
    TEMP_INBOUNDS="$(mktemp /tmp/singbox_inbounds.XXXXXX.json)"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    
    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    if ! sing-box check -c "$CONFIG_PATH"; then
        rm -f -- "$CONFIG_PATH"
        err "配置验证失败，保留现有配置，停止安装"
        return 1
    fi
    chmod 600 "$CONFIG_PATH"
    mv -f -- "$CONFIG_PATH" "$target_path"
    if $ENABLE_REALITY || $ENABLE_ANYTLS; then
        printf '%s' "$REALITY_PUB" > /etc/sing-box/.reality_pub
        printf '%s' "$REALITY_SID" > /etc/sing-box/.reality_sid
        chmod 600 /etc/sing-box/.reality_pub /etc/sing-box/.reality_sid
    fi

    local metadata
    metadata="$(mktemp /etc/sing-box/cache.XXXXXX.json)"
    jq -n --arg ip "$CUSTOM_IP" --arg sni "$REALITY_SNI" \
        '{CUSTOM_IP:$ip, REALITY_SNI:$sni}' > "$metadata"
    chmod 600 "$metadata"
    mv -f -- "$metadata" /etc/sing-box/.config_cache
    info "配置校验通过，连接信息已保存为 JSON"

}

# 调用配置生成
create_config
secure_sensitive_files

info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host="$PUB_IP"
    [[ "$host" != *:* ]] || host="[$host]"
    
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi
    
    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi
    
    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): ${REALITY_SNI:-addons.mozilla.org}"
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: /etc/sing-box/certs/"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Create newly generated credentials and config files as owner-only by default.
umask 077

# Shared validation; normalize ports before using them as JSON or sed input.
validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || { err "端口必须是 1-65535 的整数"; return 1; }
    (( 10#$value >= 1 && 10#$value <= 65535 )) || { err "端口超出范围"; return 1; }
}
validate_host() {
    [[ -n "$1" && "$1" != *[!A-Za-z0-9.:%_-]* ]] ||
        { err "IP/域名包含非法字符"; return 1; }
}
install_upstream() {
    local installer status=0
    installer="$(mktemp /tmp/singbox-upstream.XXXXXX.sh)" || return 1
    if curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 10 --max-time 120 \
        --retry 2 -o "$installer" https://sing-box.app/install.sh &&
        [ -s "$installer" ] && bash -n "$installer"; then
        bash "$installer" || status=$?
    else
        err "上游安装脚本下载或语法检查失败"
        status=1
    fi
    rm -f -- "$installer"
    return "$status"
}

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"
[ "$(id -u)" = 0 ] || { err "请使用 sudo sb"; exit 1; }

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" start
    else
        systemctl start "$SERVICE_NAME"
    fi
}
service_stop() {
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" stop
    else
        systemctl stop "$SERVICE_NAME"
    fi
}
service_restart() {
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" restart
    else
        systemctl restart "$SERVICE_NAME"
    fi
}
service_status() {
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" status
    else
        systemctl status "$SERVICE_NAME" --no-pager
    fi
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
read_config() {
    jq -e '.inbounds | type == "array"' "$CONFIG_PATH" >/dev/null 2>&1 ||
        { err "配置不存在或 JSON 无效"; return 1; }
    ENABLE_SS=$(jq -r 'any(.inbounds[]; .type=="shadowsocks")' "$CONFIG_PATH")
    ENABLE_HY2=$(jq -r 'any(.inbounds[]; .type=="hysteria2")' "$CONFIG_PATH")
    ENABLE_TUIC=$(jq -r 'any(.inbounds[]; .type=="tuic")' "$CONFIG_PATH")
    ENABLE_REALITY=$(jq -r 'any(.inbounds[]; .type=="vless")' "$CONFIG_PATH")
    ENABLE_ANYTLS=$(jq -r 'any(.inbounds[]; .type=="anytls")' "$CONFIG_PATH")
    CUSTOM_IP=""
    if [ -f "$CACHE_FILE" ]; then
        if jq -e 'type=="object"' "$CACHE_FILE" >/dev/null 2>&1; then
            CUSTOM_IP=$(jq -r '.CUSTOM_IP // ""' "$CACHE_FILE")
        else
            # Legacy cache migration reads only a literal value; never source shell code.
            CUSTOM_IP=$(awk '/^CUSTOM_IP=/{sub(/^CUSTOM_IP=/,""); value=$0} END{print value}' "$CACHE_FILE")
        fi
        if [ -n "$CUSTOM_IP" ]; then
            validate_host "$CUSTOM_IP" || return 1
        fi
    fi
    REALITY_SNI=$(jq -r '[.inbounds[] | select(.tls.reality.enabled==true) | .tls.server_name][0] // "addons.mozilla.org"' "$CONFIG_PATH")
    REALITY_SID=$(jq -r '[.inbounds[] | select(.tls.reality.enabled==true) | .tls.reality.short_id[0]][0] // ""' "$CONFIG_PATH")
    REALITY_PUB=""
    if [ -f /etc/sing-box/.reality_pub ]; then
        REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
    fi
    if $ENABLE_SS; then
        SS_PORT=$(jq -r '[.inbounds[] | select(.type=="shadowsocks")][0].listen_port' "$CONFIG_PATH")
        SS_PSK=$(jq -r '[.inbounds[] | select(.type=="shadowsocks")][0].password' "$CONFIG_PATH")
        SS_METHOD=$(jq -r '[.inbounds[] | select(.type=="shadowsocks")][0].method' "$CONFIG_PATH")
    fi
    if $ENABLE_HY2; then
        HY2_PORT=$(jq -r '[.inbounds[] | select(.type=="hysteria2")][0].listen_port' "$CONFIG_PATH")
        HY2_PSK=$(jq -r '[.inbounds[] | select(.type=="hysteria2")][0].users[0].password' "$CONFIG_PATH")
    fi
    if $ENABLE_TUIC; then
        TUIC_PORT=$(jq -r '[.inbounds[] | select(.type=="tuic")][0].listen_port' "$CONFIG_PATH")
        TUIC_UUID=$(jq -r '[.inbounds[] | select(.type=="tuic")][0].users[0].uuid' "$CONFIG_PATH")
        TUIC_PSK=$(jq -r '[.inbounds[] | select(.type=="tuic")][0].users[0].password' "$CONFIG_PATH")
    fi
    if $ENABLE_REALITY; then
        REALITY_PORT=$(jq -r '[.inbounds[] | select(.type=="vless")][0].listen_port' "$CONFIG_PATH")
        REALITY_UUID=$(jq -r '[.inbounds[] | select(.type=="vless")][0].users[0].uuid' "$CONFIG_PATH")
    fi
    if $ENABLE_ANYTLS; then
        ANYTLS_PORT=$(jq -r '[.inbounds[] | select(.type=="anytls")][0].listen_port' "$CONFIG_PATH")
        ANYTLS_USER=$(jq -r '[.inbounds[] | select(.type=="anytls")][0].users[0].name' "$CONFIG_PATH")
        ANYTLS_PSK=$(jq -r '[.inbounds[] | select(.type=="anytls")][0].users[0].password' "$CONFIG_PATH")
    fi
    return 0
}

# 获取公网IP（原始方法）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    [[ "$PUBLIC_IP" != *:* ]] || PUBLIC_IP="[$PUBLIC_IP]"
    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$URI_FILE"
        echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    local candidate
    candidate="$(mktemp /etc/sing-box/config.XXXXXX.json)" || return 1
    cp "$CONFIG_PATH" "$candidate" || return 1
    if ! ${EDITOR:-vi} "$candidate"; then
        rm -f -- "$candidate"; return 1
    fi
    apply_candidate "$candidate" || return 1
    generate_uris
}

# Validate and commit a candidate before restarting; restore on failed startup.
apply_candidate() {
    local candidate="$1" backup
    if ! sing-box check -c "$candidate"; then
        rm -f -- "$candidate"
        err "配置校验失败，现有服务未改动"
        return 1
    fi
    backup="$(mktemp /etc/sing-box/rollback.XXXXXX.json)" || return 1
    cp "$CONFIG_PATH" "$backup" || return 1
    chmod 600 "$backup" "$candidate"
    mv -f -- "$candidate" "$CONFIG_PATH" || return 1
    if service_restart; then
        sleep 2
        if service_status >/dev/null 2>&1; then
            info "服务已更新；备份: $backup"
            return 0
        fi
    fi
    cp "$backup" "$CONFIG_PATH"
    service_restart || true
    err "新配置启动失败，已恢复原配置；备份: $backup"
    return 1
}
action_reset_port() {
    local protocol="$1" current new_port candidate
    read_config || return 1
    current=$(jq -r --arg p "$protocol" '[.inbounds[] | select(.type==$p)][0].listen_port // empty' "$CONFIG_PATH")
    [ -n "$current" ] || { err "该协议未启用"; return 1; }
    read -r -p "输入 $protocol 新端口（回车保持 $current）: " new_port
    new_port="${new_port:-$current}"
    validate_port "$new_port" || return 1
    new_port="$((10#$new_port))"
    if jq -e --arg p "$protocol" --argjson port "$new_port" \
        'any(.inbounds[]; .type!=$p and .listen_port==$port)' "$CONFIG_PATH" >/dev/null; then
        err "端口与其他协议冲突"; return 1
    fi
    candidate="$(mktemp /etc/sing-box/config.XXXXXX.json)" || return 1
    if ! jq --arg p "$protocol" --argjson port "$new_port" \
        '.inbounds |= map(if .type==$p then .listen_port=$port else . end)' \
        "$CONFIG_PATH" > "$candidate"; then
        rm -f -- "$candidate"; return 1
    fi
    apply_candidate "$candidate" || return 1
    generate_uris
}
action_reset_ss() { action_reset_port shadowsocks; }
action_reset_hy2() { action_reset_port hysteria2; }
action_reset_tuic() { action_reset_port tuic; }
action_reset_reality() { action_reset_port vless; }
action_reset_anytls() { action_reset_port anytls; }

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || { install_upstream || return 1; }
    else
        install_upstream || return 1
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        if command -v apt-get >/dev/null 2>&1; then
            apt-get purge -y sing-box >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf remove -y sing-box >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y sing-box >/dev/null 2>&1 || true
        fi
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

# 生成线路机脚本
action_generate_relay() {
    read_config || return 1
    
    # Reuse the existing SS outbound. Do not silently add protocols to a live server.
    if [ "$ENABLE_SS" != true ]; then
        err "生成中转脚本需要已有 Shadowsocks 入站，请先启用 SS"
        return 1
    fi
    validate_port "$SS_PORT" || return 1
    # Values become literal shell heredoc text on the relay. Reject metacharacters.
    [[ "$SS_PSK" =~ ^[A-Za-z0-9+/=_-]+$ ]] ||
        { err "SS 密码包含中转模板不支持的字符"; return 1; }
    [[ "$SS_METHOD" =~ ^[A-Za-z0-9-]+$ ]] || return 1
    [[ "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

    # 线路机模板使用 CUSTOM_IP（若设置）或当前公共 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    validate_host "$INBOUND_IP" || return 1
    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="$(mktemp /tmp/relay-install.XXXXXX.sh)"
    
    info "正在生成线路机脚本: $RELAY_SCRIPT"
    
    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Create newly generated credentials and config files as owner-only by default.
umask 077

# Shared validation; normalize ports before using them as JSON or sed input.
validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || { err "端口必须是 1-65535 的整数"; return 1; }
    (( 10#$value >= 1 && 10#$value <= 65535 )) || { err "端口超出范围"; return 1; }
}
validate_host() {
    [[ -n "$1" && "$1" != *[!A-Za-z0-9.:%_-]* ]] ||
        { err "IP/域名包含非法字符"; return 1; }
}
install_upstream() {
    local installer status=0
    installer="$(mktemp /tmp/singbox-upstream.XXXXXX.sh)" || return 1
    if curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 10 --max-time 120 \
        --retry 2 -o "$installer" https://sing-box.app/install.sh &&
        [ -s "$installer" ] && bash -n "$installer"; then
        bash "$installer" || status=$?
    else
        err "上游安装脚本下载或语法检查失败"
        status=1
    fi
    rm -f -- "$installer"
    return "$status"
}

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) install_upstream ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid)

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair)
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex)
[ -n "$REALITY_PK" ] && [ -n "$REALITY_PUB" ] && [ -n "$REALITY_SID" ] || exit 1

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"
validate_port "$LISTEN_PORT" || exit 1
LISTEN_PORT="$((10#$LISTEN_PORT))"

mkdir -p /etc/sing-box

[ ! -f /etc/sing-box/config.json ] || { err "线路机已有配置，停止以避免覆盖"; exit 1; }
chmod 700 /etc/sing-box
RELAY_CONFIG="$(mktemp /etc/sing-box/config.XXXXXX.json)"
cat > "$RELAY_CONFIG" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF
if ! sing-box check -c "$RELAY_CONFIG"; then
    rm -f -- "$RELAY_CONFIG"; exit 1
fi
chmod 600 "$RELAY_CONFIG"
mv -- "$RELAY_CONFIG" /etc/sing-box/config.json

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

# 生成并保存链接
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-addons.mozilla.org}|g" "$RELAY_SCRIPT"
    
    chmod 700 "$RELAY_SCRIPT"
    
    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    info "脚本包含 SS 密码，请安全传输该文件；不在终端打印凭据"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   将 $RELAY_SCRIPT 安全复制到线路机，再以 root 运行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=4
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri || warn "操作未完成，请检查错误信息" ;;
        2) action_view_config ;;
        3) action_edit_config || warn "操作未完成，请检查错误信息" ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss || warn "操作未完成，请检查错误信息" ;;
                reset_hy2) action_reset_hy2 || warn "操作未完成，请检查错误信息" ;;
                reset_tuic) action_reset_tuic || warn "操作未完成，请检查错误信息" ;;
                reset_reality) action_reset_reality || warn "操作未完成，请检查错误信息" ;;
                reset_anytls) action_reset_anytls || warn "操作未完成，请检查错误信息" ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status || true ;;
                update) action_update || warn "操作未完成，请检查错误信息" ;;
                relay) action_generate_relay || warn "操作未完成，请检查错误信息" ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可输入 sb 打开管理面板"

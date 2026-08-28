#!/bin/sh

set -eu

VERSION="v26.3.27"
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${VERSION}/Xray-linux-64.zip"

BASE_DIR="$(pwd)"
XRAY_DIR="${BASE_DIR}/xray"
INIT_FILE="/etc/init.d/xray"
CONFIG_FILE="${XRAY_DIR}/config.json"

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。" >&2
    exit 1
fi

# 安装依赖
for cmd in wget unzip sed grep awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：缺少 ${cmd}，请执行：apk add ${cmd}" >&2
        exit 1
    fi
done

if ! command -v curl >/dev/null 2>&1; then
    apk add --no-cache curl >/dev/null 2>&1
fi

# 创建 Xray 目录
mkdir -p "$XRAY_DIR"
cd "$XRAY_DIR"

# 下载
wget -q -O Xray-linux-64.zip "$DOWNLOAD_URL"

# 解压
unzip -oq Xray-linux-64.zip
rm -f Xray-linux-64.zip

chmod +x ./xray

if [ ! -x "./xray" ]; then
    echo "错误：Xray 可执行文件不存在。" >&2
    exit 1
fi

# UUID
UUID="$(./xray uuid | tr -d '\r\n')"

if [ -z "$UUID" ]; then
    echo "错误：UUID 生成失败。" >&2
    exit 1
fi

# VLESS encryption
VLESSENC_OUTPUT="$(./xray vlessenc)"

DECRYPTION="$(printf '%s\n' "$VLESSENC_OUTPUT" |
    sed -n 's/^[[:space:]]*"decryption":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)"

ENCRYPTION="$(printf '%s\n' "$VLESSENC_OUTPUT" |
    sed -n 's/^[[:space:]]*"encryption":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)"

if [ -z "$DECRYPTION" ] || [ -z "$ENCRYPTION" ]; then
    echo "错误：无法解析 vlessenc 输出。" >&2
    exit 1
fi

# 输入端口
while true; do
    printf "请输入 Xray 监听端口: " >&2
    read PORT

    case "$PORT" in
        ''|*[!0-9]*)
            echo "错误：端口必须是数字。" >&2
            ;;
        *)
            if [ "$PORT" -ge 1 ] 2>/dev/null &&
               [ "$PORT" -le 65535 ] 2>/dev/null; then
                break
            fi

            echo "错误：端口范围必须是 1-65535。" >&2
            ;;
    esac
done

# 创建 config.json
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-encryption",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "${DECRYPTION}"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "port": "25,135,137,138,139,445,465,587",
        "outboundTag": "BLOCK"
      }
    ],
    "domainStrategy": "AsIs"
  }
}
EOF

# 检查配置
if ! ./xray run -test -c "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "错误：Xray 配置检查失败。" >&2
    exit 1
fi

# 创建 OpenRC 服务
cat > "$INIT_FILE" <<EOF
#!/sbin/openrc-run

name="Xray Service"
description="Xray-core proxy daemon"

directory="${XRAY_DIR}"
command="${XRAY_DIR}/xray"
command_args="run -c ${XRAY_DIR}/config.json"
command_background="true"

pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF

chmod +x "$INIT_FILE"

# 开机自启
if ! rc-update add xray default >/dev/null 2>&1; then
    echo "Xray 开机自启：失败" >&2
    exit 1
fi

# 启动服务
if rc-service xray start >/dev/null 2>&1; then
    SERVICE_STATUS="Xray 服务启动：成功"
else
    SERVICE_STATUS="Xray 服务启动：失败"
fi

# 获取 hostname
HOSTNAME="$(hostname)"

# 获取公共 IPv6
IPV6="$(curl -6 -fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"

if [ -z "$IPV6" ]; then
    IPV6="$(curl -6 -fsS --max-time 10 https://ifconfig.co/ip 2>/dev/null || true)"
fi

if [ -z "$IPV6" ]; then
    echo "错误：无法获取公共 IPv6 地址。" >&2
    exit 1
fi

# 输出最终结果
echo "$SERVICE_STATUS"
printf '%s\n' \
    "{name: \"${HOSTNAME}-vless-enc\", type: vless, server: ${IPV6}, port: ${PORT}, uuid: ${UUID}, network: tcp, flow: xtls-rprx-vision, encryption: \"${ENCRYPTION}\", tls: false, udp: true}"

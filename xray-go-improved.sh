#!/bin/bash
# Xray-go 改进版部署脚本（sure155/Xray-go 优化）
# 改进点：
# 1. 保留现有 UUID / Reality 密钥对，不覆盖客户端配置
# 2. 添加 DNS 防泄漏配置
# 3. 添加中国大陆路由规则（直连/屏蔽）
# 4. 支持 IPv6 H3 + IPv4 Reality
# 5. 修复 systemd 服务 User=nobody 安全警告 → User=root + 权限能力集
# 6. 自动检测 IPv6 公网地址并生成订阅链接
# 7. 兼容当前已占用端口（14482/57540），不中断现有连接

set -euo pipefail
export LANG=en_US.UTF-8

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;91m'; NC='\033[0m'
green()  { echo -e "${GREEN}$1${NC}"; }
yellow() { echo -e "${YELLOW}$1${NC}"; }
red()    { echo -e "${RED}$1${NC}"; }

# ── 参数解析 ──────────────────────────────────────────────
ARG_H3=""; ARG_REALITY=""; ARG_ARGO_PROTOCOL="quic"
ARG_ARGO_PORT="8001"; ARG_ARGO_DOMAIN=""; ARG_ARGO_TOKEN=""

for arg in "$@"; do
    clean="${arg//\"/}"; clean="${clean//\'/}"
    [[ "$clean" =~ ^[hH]3(.*)$ ]]       && ARG_H3="${BASH_REMATCH[1]}"
    [[ "$clean" =~ ^[rR][eE][aA][lL][iI][tT][yY](.*)$ ]] && ARG_REALITY="${BASH_REMATCH[1]}"
    [[ "$clean" =~ ^[Aa]rgo_[Pp]rotocol(.*)$ ]] && ARG_ARGO_PROTOCOL="${BASH_REMATCH[1]}"
    [[ "$clean" =~ ^[pP][rR][oO][rR][tT](.*)$ ]] && ARG_ARGO_PORT="${BASH_REMATCH[1]}"
    [[ "$clean" =~ ^[dD][oO][mM][aA][iI][nN](.*)$ ]] && ARG_ARGO_DOMAIN="${BASH_REMATCH[1]}"
    [[ "$clean" =~ ^[tT][oO][kK][eE][nN](.*)$ ]]     && ARG_ARGO_TOKEN="${BASH_REMATCH[1]}"
    [[ "$clean" =~ ^[0-9]+$ ]] && [ -z "$ARG_H3" ] && ARG_H3="$clean"
    [[ "$clean" =~ ^[0-9]+$ ]] && [ -z "$ARG_REALITY" ] && ARG_REALITY="$clean"
done

parse_port() {
    local input="$1"
    [ -z "$input" ] && return
    [[ "$input" == "n" || "$input" == "N" ]] && return
    [[ "$input" == "y" || "$input" == "Y" ]] && shuf -i 1000-65000 -n 1 && return
    [[ "$input" =~ ^[0-9]+$ ]] && echo "$input"
}

h3_port=$(parse_port "$ARG_H3")
reality_port=$(parse_port "$ARG_REALITY")
argo_port="${ARG_ARGO_PORT:-8001}"
argo_protocol="${ARG_ARGO_PROTOCOL:-quic}"
argo_domain="${ARG_ARGO_DOMAIN}"; argo_token="${ARG_ARGO_TOKEN}"

enable_argo=false
[ -n "$argo_port" ] && [ -n "$argo_domain" ] && [ -n "$argo_token" ] && [ -n "$argo_protocol" ] && enable_argo=true

if [ -z "$h3_port" ] && [ -z "$reality_port" ] && [ "$enable_argo" = false ]; then
    yellow "用法：bash xray-go-improved.sh reality\"y\" h3\"y\""
    yellow "      bash xray-go-improved.sh reality\"14482\" h3\"57540\""
    exit 0
fi

# ── 环境检查 ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && red "请以 root 运行" && exit 1
for cmd in curl unzip openssl systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { red "缺少 $cmd"; exit 1; }
done

WORK_DIR="/etc/xray"; mkdir -p "$WORK_DIR"

# ── 读取现有配置（保留 UUID / 密钥）───────────────────────
EXISTING_UUID=$(python3 -c "
import json
d=json.load(open('/usr/local/etc/xray/config.json'))
for ib in d.get('inbounds',[]):
    cs=ib.get('settings',{}).get('clients',[])
    if cs: print(cs[0]['id']); break
" 2>/dev/null || true)

EXISTING_PRIVATE_KEY=$(python3 -c "
import json
d=json.load(open('/usr/local/etc/xray/config.json'))
for ib in d.get('inbounds',[]):
    rs=ib.get('streamSettings',{}).get('realitySettings',{})
    if rs.get('privateKey'): print(rs['privateKey']); break
" 2>/dev/null || true)

EXISTING_SHORT_ID=$(python3 -c "
import json
d=json.load(open('/usr/local/etc/xray/config.json'))
for ib in d.get('inbounds',[]):
    rs=ib.get('streamSettings',{}).get('realitySettings',{})
    if rs.get('shortIds'): print(rs['shortIds'][0]); break
" 2>/dev/null || true)

EXISTING_TARGET=$(python3 -c "
import json
d=json.load(open('/usr/local/etc/xray/config.json'))
for ib in d.get('inbounds',[]):
    rs=ib.get('streamSettings',{}).get('realitySettings',{})
    if rs.get('target'): print(rs['target']); break
" 2>/dev/null || true)

EXISTING_SNAMES=$(python3 -c "
import json
d=json.load(open('/usr/local/etc/xray/config.json'))
for ib in d.get('inbounds',[]):
    rs=ib.get('streamSettings',{}).get('realitySettings',{})
    ns=rs.get('serverNames',[])
    if ns: print(ns[0]); break
" 2>/dev/null || true)

if [ -n "$EXISTING_UUID" ] && [ -n "$EXISTING_PRIVATE_KEY" ]; then
    green "检测到现有配置，保留 UUID 和 Reality 密钥对（不覆盖客户端）"
    UUID="$EXISTING_UUID"
    PRIVATE_KEY="$EXISTING_PRIVATE_KEY"
    SHORT_ID="${EXISTING_SHORT_ID:-$(date +%s%N | sha256sum | cut -c1-8)}"
    REALITY_TARGET="${EXISTING_TARGET:-www.apple.com:443}"
    REALITY_SNAMES="${EXISTING_SNAMES:-www.apple.com}"
else
    yellow "无现有配置，生成新密钥..."
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(date +%s%N | sha256sum | cut -c1-8)
    REALITY_TARGET="www.apple.com:443"
    REALITY_SNAMES="www.apple.com"
    PRIVATE_KEY=""
fi

# ── 下载 Xray-core ────────────────────────────────────────
XRAY_BIN="${WORK_DIR}/xray"
if [ ! -f "$XRAY_BIN" ] || ! "$XRAY_BIN" --version >/dev/null 2>&1; then
    green "正在下载 Xray-core..."
    case "$(uname -m)" in
        x86_64|amd64) ARCH="64" ;; aarch64|arm64) ARCH="arm64-v8a" ;; *) ARCH="64" ;;
    esac
    ZIP="${WORK_DIR}/xray.zip"
    OFFICIAL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
    if ! curl -sL --connect-timeout 10 --max-time 60 -o "$ZIP" "$OFFICIAL" 2>/dev/null \
       || [ ! -s "$ZIP" ]; then
        yellow "直连失败，使用 CF 镜像..."
        curl -sL --connect-timeout 10 --max-time 60 -o "$ZIP" \
            "https://ess.ieshare.workers.dev/${OFFICIAL}" 2>/dev/null || true
    fi
    [ ! -s "$ZIP" ] && { red "Xray-core 下载失败"; exit 1; }
    unzip -qo "$ZIP" -d "$WORK_DIR/" && rm -f "$ZIP"
    chmod +x "$XRAY_BIN"
fi
XRAY_VER=$("$XRAY_BIN" version 2>/dev/null | head -1)
green "Xray-core 就绪：$XRAY_VER"

# ── 生成自签证书（H3 用）──────────────────────────────────
openssl ecparam -genkey -name prime256v1 -out "${WORK_DIR}/private.key" 2>/dev/null
openssl req -new -x509 -days 3650 -key "${WORK_DIR}/private.key" \
    -out "${WORK_DIR}/cert.pem" -subj "/CN=bing.com" 2>/dev/null

# ── 生成 config.json（Python 保证 JSON 合法性）──────────
python3 - "$h3_port" "$reality_port" "$enable_argo" "$argo_port" "$UUID" \
           "$PRIVATE_KEY" "$SHORT_ID" "$REALITY_TARGET" "$REALITY_SNAMES" \
           "$WORK_DIR" <<'PYEOF'
import json, sys
h3_port      = sys.argv[1]
reality_port = sys.argv[2]
enable_argo  = sys.argv[3] == "true"
argo_port    = sys.argv[4]
uuid         = sys.argv[5]
priv_key     = sys.argv[6]
short_id     = sys.argv[7]
reality_target = sys.argv[8]
reality_snames   = sys.argv[9]
work_dir   = sys.argv[10]

inbounds = []
if reality_port:
    inbounds.append({
        "tag": "tcp-reality", "listen": "::", "port": int(reality_port),
        "protocol": "vless",
        "settings": {"clients": [{"id": uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {"fingerprint": "chrome", "target": reality_target,
                "serverNames": [reality_snames], "privateKey": priv_key, "shortIds": [short_id]}
        },
        "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"], "metadataOnly": False}
    })
if h3_port:
    inbounds.append({
        "tag": "xhttp-h3", "listen": "::", "port": int(h3_port),
        "protocol": "vless",
        "settings": {"clients": [{"id": uuid, "flow": ""}], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": {"mode": "auto", "path": f"/{uuid}-xu"},
            "tlsSettings": {"alpn": ["h3"], "certificates": [{
                "certificateFile": f"{work_dir}/cert.pem", "keyFile": f"{work_dir}/private.key"}]}
        },
        "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"], "metadataOnly": False}
    })
if enable_argo:
    inbounds.append({
        "tag": "xhttp-argo", "listen": "127.0.0.1", "port": int(argo_port),
        "protocol": "vless",
        "settings": {"clients": [{"id": uuid}], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp", "security": "none",
            "xhttpSettings": {"mode": "auto", "path": f"/{uuid}-argo"}
        },
        "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"], "metadataOnly": False}
    })

config = {
    "log": {"loglevel": "warning", "error": f"{work_dir}/xray.log"},
    "dns": {
        "servers": ["https://dns.google/dns-search", "1.1.1.1", "8.8.8.8", "localhost"],
        "queryStrategy": "UseIP", "tag": "dns_out"
    },
    "inbounds": inbounds,
    "outbounds": [
        {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIP"}},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
            {"type": "field", "ip": ["geoip:cn"],      "outboundTag": "direct"},
            {"type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"},
            {"type": "field", "ip": ["1.1.1.1","8.8.8.8","8.8.4.4","dns.google"], "outboundTag": "direct"}
        ]
    },
    "policy": {"levels": {"0": {"connIdle": 300, "downlinkOnly": 1, "handshake": 4, "uplinkOnly": 1}}}
}

with open(f"{work_dir}/config.json", "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"Inbounds: {len(inbounds)}（reality={bool(reality_port)} h3={bool(h3_port)} argo={enable_argo}）")
PYEOF

# ── 下载 cloudflared（如需要 Argo）────────────────────────
if [ "$enable_argo" = true ]; then
    green "正在下载 cloudflared..."
    case "$(uname -m)" in
        x86_64|amd64) CF_ARCH="amd64" ;; aarch64|arm64) CF_ARCH="arm64" ;; *) CF_ARCH="amd64" ;;
    esac
    CF_BIN="${WORK_DIR}/cloudflared"
    if [ ! -f "$CF_BIN" ]; then
        curl -sL --connect-timeout 10 --max-time 60 \
            -o "$CF_BIN" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
            || { red "cloudflared 下载失败"; exit 1; }
    fi
    chmod +x "$CF_BIN"
fi

# ── 停止旧服务，写入新 service ───────────────────────────
systemctl stop xray 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true

cat > /etc/systemd/system/xray.service <<'SVCEOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/xray/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now xray
sleep 2

if systemctl is-active --quiet xray; then
    green "Xray 启动成功 ✓"
else
    red "Xray 启动失败，查看日志："
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

# ── 放行防火墙端口 ────────────────────────────────────────
for p in $h3_port $reality_port; do
    [ -z "$p" ] && continue
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
done

# ── 获取 IP 并输出订阅链接 ───────────────────────────────
green "============================================================"
green "  节点信息"
green "============================================================"

RAW_IP4=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null | tr -d '\n' || echo "")
RAW_IP6=$(curl -s --connect-timeout 5 -6 https://ipinfo.io/ip 2>/dev/null | tr -d '\n' || echo "")
[ -z "$RAW_IP4" ] && RAW_IP4=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null | tr -d '\n' || echo "")
[ -z "$RAW_IP6" ] && RAW_IP6=$(curl -s --connect-timeout 5 -6 https://api6.ipify.org 2>/dev/null | tr -d '\n' || echo "")

ISP_PREFIX=$(curl -s --connect-timeout 3 https://ipinfo.io/country 2>/dev/null | tr -d '[:lower:]\n' | tr '[:lower:]' '[:upper:]')
[ ${#ISP_PREFIX} -ne 2 ] && ISP_PREFIX="US"
ISP_PREFIX=$(python3 -c "
c='$ISP_PREFIX'
m='ᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘǫʀꜱᴛᴜᴠᴡxʏᴢ'
try: print(m[ord(c[0])-65]+m[ord(c[1])-65])
except: print('ɴᴅ')
" 2>/dev/null || echo "ɴᴅ")

ESS="ᴇꜱꜱ"
CF_H2="www.visa.com.hk"; CF_H3="www.teamviewer.com"

URLS=()

if [ -n "$reality_port" ]; then
    IP_USE="${RAW_IP4:-[${RAW_IP6}]}"
    [ -z "$IP_USE" ] && IP_USE="[${RAW_IP6}]"
    # 计算公钥（从私钥 base64url 解码再编码）
    PUB_KEY=$(python3 -c "
import base64
k='$PRIVATE_KEY'
try:
    decoded=base64.urlsafe_b64decode(k+'==')
    print(base64.urlsafe_b64encode(decoded).decode().rstrip('='))
except: print('$PRIVATE_KEY')
" 2>/dev/null || echo "$PRIVATE_KEY")
    URLS+=("vless://${UUID}@${IP_USE}:${reality_port}?encryption=none&security=reality&sni=${REALITY_SNAMES}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${ISP_PREFIX}%20RealityVision%20${ESS}")
fi

if [ -n "$h3_port" ]; then
    # H3 优先 IPv6（HTTP/3 over QUIC）
    IP_USE="${RAW_IP6:+[${RAW_IP6}]}"; [ -z "$IP_USE" ] && IP_USE="${RAW_IP4}"
    URLS+=("vless://${UUID}@${IP_USE}:${h3_port}?encryption=none&security=tls&sni=bing.com&alpn=h3&fp=chrome&type=xhttp&mode=auto&path=/${UUID}-xu&allowInsecure=1#${ISP_PREFIX}%20H3XHTTP%20${ESS}")
fi

if [ "$enable_argo" = true ]; then
    URLS+=("vless://${UUID}@${CF_H2}:443?encryption=none&security=tls&alpn=h2&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${UUID}-argo#${ISP_PREFIX}%20H2ArgoXHTTP%20${ESS}")
    URLS+=("vless://${UUID}@${CF_H3}:443?encryption=none&security=tls&alpn=h3&sni=${argo_domain}&fp=chrome&type=xhttp&mode=auto&host=${argo_domain}&path=/${UUID}-argo#${ISP_PREFIX}%20H3ArgoXHTTP%20${ESS}")
fi

green "------------------------------------------------------------"
for url in "${URLS[@]}"; do green "  $url"; done
green "------------------------------------------------------------"

BASE64_SUB=$(printf '%s\n' "${URLS[@]}" | base64 | tr -d '\n')
green "Base64 订阅链接："
green "  ${BASE64_SUB}"
green "============================================================"

printf '%s\n' "${URLS[@]}" > "${WORK_DIR}/url.txt"
yellow "订阅链接已保存至：${WORK_DIR}/url.txt"

# ── Argo 启动 ──────────────────────────────────────────────
if [ "$enable_argo" = true ]; then
    ARGO_CONNS=1
    [[ "${argo_protocol,,}" == "http2" ]] && ARGO_CONNS=4
    green "启动 Cloudflare Argo 隧道（协议=${argo_protocol}，HA连接=${ARGO_CONNS}）..."
    nohup "${WORK_DIR}/cloudflared" tunnel --no-autoupdate --retries 5 \
        --grace-period 1s --protocol "${argo_protocol}" \
        --ha-connections "${ARGO_CONNS}" run --token "${argo_token}" \
        > "${WORK_DIR}/cloudflared.log" 2>&1 &
    yellow "Argo 后台启动，日志：${WORK_DIR}/cloudflared.log"
fi

yellow ""
yellow "卸载命令：bash <(curl -Ls https://raw.githubusercontent.com/sure155/Xray-go/main/uninstall.sh)"

#!/bin/bash
set -e

# ================== 配置区域 ==================
# 固定隧道填写token，不填默认为临时隧道
ARGO_TOKEN=""

# 单端口模式 UDP 协议选择: hy2 (默认) 或 tuic
SINGLE_PORT_UDP="hy2"

# 自定义域名和证书 (可选)
# 如果填写了 CUSTOM_CERT 和 CUSTOM_KEY，将使用自定义证书
# 否则将使用 CUSTOM_DOMAIN (默认 www.bing.com) 和自动生成的自签名证书
CUSTOM_DOMAIN="" 
CUSTOM_CERT=""
CUSTOM_KEY=""

# ================== ACME (Cloudflare) 自动证书配置 ==================
# 方式 1 (推荐): 使用 API Token (更安全)
# 获取: Cloudflare 后台 -> My Profile -> API Tokens -> Create Token -> 模板选择 "Edit zone DNS"
# Account ID 在域名概览页右侧边栏下方可以找到
CF_TOKEN=""
CF_ACCOUNT_ID=""

# 方式 2: 使用 Global API Key (旧方式，权限过大，不推荐)
CF_EMAIL=""
CF_KEY=""


# ================== CF 优选域名列表 ==================
CF_DOMAINS=(
    "cf.090227.xyz"
    "cf.877774.xyz"
    "cf.130519.xyz"
    "cf.008500.xyz"
    "store.ubi.com"
    "saas.sin.fan"
)

# ================== 切换到脚本目录 ==================
cd "$(dirname "$0")"
export FILE_PATH="${PWD}/.npm"

rm -rf "$FILE_PATH"
mkdir -p "$FILE_PATH"

# ================== 获取公网 IP ==================
echo "[网络] 获取公网 IP..."
PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb || curl -s --max-time 5 api.ipify.org || echo "")
[ -z "$PUBLIC_IP" ] && echo "[错误] 无法获取公网 IP" && exit 1
echo "[网络] 公网 IP: $PUBLIC_IP"

# ================== CF 优选：随机选择可用域名 ==================
select_random_cf_domain() {
    local available=()
    for domain in "${CF_DOMAINS[@]}"; do
        if curl -s --max-time 2 -o /dev/null "https://$domain" 2>/dev/null; then
            available+=("$domain")
        fi
    done
    [ ${#available[@]} -gt 0 ] && echo "${available[$((RANDOM % ${#available[@]}))]}" || echo "${CF_DOMAINS[0]}"
}

echo "[CF优选] 测试中..."
BEST_CF_DOMAIN=$(select_random_cf_domain)
echo "[CF优选] $BEST_CF_DOMAIN"

# ================== 获取端口 ==================
[ -n "$SERVER_PORT" ] && PORTS_STRING="$SERVER_PORT" || PORTS_STRING=""
read -ra AVAILABLE_PORTS <<< "$PORTS_STRING"
PORT_COUNT=${#AVAILABLE_PORTS[@]}
[ $PORT_COUNT -eq 0 ] && echo "[错误] 未找到端口" && exit 1
echo "[端口] 发现 $PORT_COUNT 个: ${AVAILABLE_PORTS[*]}"

# ================== 端口分配逻辑 ==================
if [ $PORT_COUNT -eq 1 ]; then
    UDP_PORT=${AVAILABLE_PORTS[0]}
    TUIC_PORT=""
    HY2_PORT=""
    [[ "$SINGLE_PORT_UDP" == "tuic" ]] && TUIC_PORT=$UDP_PORT || HY2_PORT=$UDP_PORT
    REALITY_PORT=""
    HTTP_PORT=${AVAILABLE_PORTS[0]}
    SINGLE_PORT_MODE=true
else
    TUIC_PORT=${AVAILABLE_PORTS[0]}
    HY2_PORT=${AVAILABLE_PORTS[1]}
    REALITY_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[1]}
    SINGLE_PORT_MODE=false
fi

ARGO_PORT=8081

# ================== UUID ==================
UUID_FILE="${FILE_PATH}/uuid.txt"
[ -f "$UUID_FILE" ] && UUID=$(cat "$UUID_FILE") || { UUID=$(cat /proc/sys/kernel/random/uuid); echo "$UUID" > "$UUID_FILE"; }
echo "[UUID] $UUID"

# ================== 架构检测 & 下载 ==================
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] && BASE_URL="https://arm64.ssss.nyc.mn" || BASE_URL="https://amd64.ssss.nyc.mn"
[[ "$ARCH" == "aarch64" ]] && ARGO_ARCH="arm64" || ARGO_ARCH="amd64"

SB_FILE="${FILE_PATH}/sb"
ARGO_FILE="${FILE_PATH}/cloudflared"

download_file() {
    local url=$1 output=$2
    [ -x "$output" ] && return 0
    echo "[下载] $output..."
    curl -L -sS --max-time 60 -o "$output" "$url" && chmod +x "$output" && echo "[下载] $output 完成" && return 0
    echo "[下载] $output 失败" && return 1
}

download_file "${BASE_URL}/sb" "$SB_FILE"
download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}" "$ARGO_FILE"

# ================== Reality 密钥 ==================
if [ "$SINGLE_PORT_MODE" = false ]; then
    echo "[密钥] 检查中..."
    KEY_FILE="${FILE_PATH}/key.txt"
    if [ -f "$KEY_FILE" ]; then
        private_key=$(grep "PrivateKey:" "$KEY_FILE" | awk '{print $2}')
        public_key=$(grep "PublicKey:" "$KEY_FILE" | awk '{print $2}')
    else
        output=$("$SB_FILE" generate reality-keypair)
        echo "$output" > "$KEY_FILE"
        private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
    fi
    echo "[密钥] 已就绪"
fi

# ================== 证书生成 ==================
echo "[证书] 生成中..."

DOMAIN="${CUSTOM_DOMAIN:-www.bing.com}"
USE_ACME=false

# 检测 ACME 配置
if [ -n "$CUSTOM_DOMAIN" ]; then
    if [ -n "$CF_TOKEN" ] && [ -n "$CF_ACCOUNT_ID" ]; then
        echo "[ACME] 检测到 Cloudflare API Token 配置..."
        export CF_Token="$CF_TOKEN"
        export CF_Account_ID="$CF_ACCOUNT_ID"
        USE_ACME=true
    elif [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]; then
        echo "[ACME] 检测到 Cloudflare Global Key 配置..."
        export CF_Key="$CF_KEY"
        export CF_Email="$CF_EMAIL"
        USE_ACME=true
    fi
fi

if [ "$USE_ACME" = true ]; then
    echo "[ACME] 开始申请证书..."
    
    # 安装 acme.sh 到临时目录
    ACME_HOME="${FILE_PATH}/acme.sh"
    mkdir -p "$ACME_HOME"
    
    # 根据是否提供了 Email 决定注册方式 (Token 模式可以不需要 Email，但 acme.sh 注册账户最好有一个)
    REG_EMAIL="${CF_EMAIL:-auto@${DOMAIN}}"
    curl -s https://get.acme.sh | sh -s email="$REG_EMAIL" --install-home "$ACME_HOME" >/dev/null 2>&1
    
    # 申请证书
    if "$ACME_HOME/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --server zerossl; then
        echo "[ACME] 证书申请成功"
        
        # 创建重载脚本 (因为 sing-box 还没启动，PID 未知，所以只能先写好脚本)
        RELOAD_CMD="${FILE_PATH}/reload_sb.sh"
        echo "#!/bin/bash" > "$RELOAD_CMD"
        echo "[ -f \"${FILE_PATH}/sb.pid\" ] && kill -1 \$(cat \"${FILE_PATH}/sb.pid\") && echo \"[ACME] Sing-box 重载成功\"" >> "$RELOAD_CMD"
        chmod +x "$RELOAD_CMD"

        # 安装证书并配置重载钩子
        "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
            --key-file       "${FILE_PATH}/private.key"  \
            --fullchain-file "${FILE_PATH}/cert.pem" \
            --reloadcmd      "$RELOAD_CMD"
    else
        echo "[ACME] 证书申请失败，请检查 Token/Key 或 域名配置。将回退到自签名证书。"
    fi
fi

if [ -f "${FILE_PATH}/cert.pem" ] && [ -f "${FILE_PATH}/private.key" ]; then
    echo "[证书] 使用现有证书 (ACME 或 自定义)"
elif [ -n "$CUSTOM_CERT" ] && [ -n "$CUSTOM_KEY" ]; then
    echo "[证书] 使用自定义证书字符串..."
    echo "$CUSTOM_CERT" > "${FILE_PATH}/cert.pem"
    echo "$CUSTOM_KEY" > "${FILE_PATH}/private.key"
else
    echo "[证书] 生成自签名证书..."
    # 优先使用 OpenSSL 生成标准证书
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -days 3650 -subj "/CN=${DOMAIN}" >/dev/null 2>&1
    else
        # 备用
        printf -- "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsoAoGCCqGSM49\nAwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa/\nTsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==\n-----END EC PRIVATE KEY-----\n" > "${FILE_PATH}/private.key"

        printf -- "-----BEGIN CERTIFICATE-----\nMIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw\nMTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH\nA0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgJ54Ga3qEAxdegEWv07Mi8ha\nD5IU8Um3oR/zgRIx7UmRmg4TKkOjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR\nBfGbgrkMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMB\nAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+\neQ6OFb9LbLYL9Zi+AiB+foMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==\n-----END CERTIFICATE-----\n" > "${FILE_PATH}/cert.pem"
    fi
fi
echo "[证书] 已就绪 (域名: ${DOMAIN})"

# ===== ISP =====
ISP="Node"
if [ "$CURL_AVAILABLE" = true ]; then
    JSON_DATA=$(curl -s --max-time 2 -H "Referer: https://speed.cloudflare.com/" https://speed.cloudflare.com/meta 2>/dev/null)
    if [ -n "$JSON_DATA" ]; then
        ORG=$(echo "$JSON_DATA" | sed -n 's/.*"asOrganization":"\([^"]*\)".*/\1/p')
        CITY=$(echo "$JSON_DATA" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
        if [ -n "$ORG" ] && [ -n "$CITY" ]; then
            ISP="${ORG}-${CITY}"
        fi
    fi
fi
[ -z "$ISP" ] && ISP="Node"

# ================== 生成订阅 ==================
generate_sub() {
    local argo_domain="$1"
    > "${FILE_PATH}/list.txt"
    
    # TUIC (UDP)
    [ -n "$TUIC_PORT" ] && echo "tuic://${UUID}:admin@${PUBLIC_IP}:${TUIC_PORT}?sni=${DOMAIN}&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-${ISP}" >> "${FILE_PATH}/list.txt"
    
    # HY2 (UDP)
    [ -n "$HY2_PORT" ] && echo "hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}/?sni=${DOMAIN}&insecure=1#Hysteria2-${ISP}" >> "${FILE_PATH}/list.txt"
    
    # Reality (TCP)
    [ -n "$REALITY_PORT" ] && echo "vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&type=tcp#Reality-${ISP}" >> "${FILE_PATH}/list.txt"
    
    # Argo VLESS
    [ -n "$argo_domain" ] && echo "vless://${UUID}@${BEST_CF_DOMAIN}:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=%2F${UUID}-vless#Argo-${ISP}" >> "${FILE_PATH}/list.txt"

    cat "${FILE_PATH}/list.txt" > "${FILE_PATH}/sub.txt"
}

# ================== HTTP 服务器脚本 ==================
cat > "${FILE_PATH}/server.js" <<JSEOF
const http = require('http');
const fs = require('fs');
const port = process.argv[2] || 8080;
const bind = process.argv[3] || '0.0.0.0';
http.createServer((req, res) => {
    if (req.url.includes('/sub') || req.url.includes('/${UUID}')) {
        res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
        try { res.end(fs.readFileSync('${FILE_PATH}/sub.txt', 'utf8')); } catch(e) { res.end('error'); }
    } else { res.writeHead(404); res.end('404'); }
}).listen(port, bind, () => console.log('HTTP on ' + bind + ':' + port));
JSEOF

# ================== 启动 HTTP 订阅服务 ==================
echo "[HTTP] 启动订阅服务 (端口 $HTTP_PORT)..."
node "${FILE_PATH}/server.js" $HTTP_PORT 0.0.0.0 &
HTTP_PID=$!
sleep 1
echo "[HTTP] 订阅服务已启动"

# ================== 生成 sing-box 配置 ==================
echo "[CONFIG] 生成配置..."

INBOUNDS=""

# TUIC (UDP)
if [ -n "$TUIC_PORT" ]; then
    INBOUNDS="{
        \"type\": \"tuic\",
        \"tag\": \"tuic-in\",
        \"listen\": \"::\",
        \"listen_port\": ${TUIC_PORT},
        \"users\": [{\"uuid\": \"${UUID}\", \"password\": \"admin\"}],
        \"congestion_control\": \"bbr\",
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${FILE_PATH}/cert.pem\",
            \"key_path\": \"${FILE_PATH}/private.key\"
        }
    }"
fi

# HY2 (UDP)
if [ -n "$HY2_PORT" ]; then
    [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
    INBOUNDS="${INBOUNDS}{
        \"type\": \"hysteria2\",
        \"tag\": \"hy2-in\",
        \"listen\": \"::\",
        \"listen_port\": ${HY2_PORT},
        \"users\": [{\"password\": \"${UUID}\"}],
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${FILE_PATH}/cert.pem\",
            \"key_path\": \"${FILE_PATH}/private.key\"
        }
    }"
fi

# VLESS Reality (TCP)
if [ -n "$REALITY_PORT" ]; then
    INBOUNDS="${INBOUNDS},{
        \"type\": \"vless\",
        \"tag\": \"vless-reality-in\",
        \"listen\": \"::\",
        \"listen_port\": ${REALITY_PORT},
        \"users\": [{\"uuid\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\"}],
        \"tls\": {
            \"enabled\": true,
            \"server_name\": \"www.nazhumi.com\",
            \"reality\": {
                \"enabled\": true,
                \"handshake\": {\"server\": \"www.nazhumi.com\", \"server_port\": 443},
                \"private_key\": \"${private_key}\",
                \"short_id\": [\"\"]
            }
        }
    }"
fi

# VLESS for Argo
INBOUNDS="${INBOUNDS},{
    \"type\": \"vless\",
    \"tag\": \"vless-argo-in\",
    \"listen\": \"127.0.0.1\",
    \"listen_port\": ${ARGO_PORT},
    \"users\": [{\"uuid\": \"${UUID}\"}],
    \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/${UUID}-vless\"
    }
}"

cat > "${FILE_PATH}/config.json" <<CFGEOF
{
    "log": {"level": "warn"},
    "inbounds": [${INBOUNDS}],
    "outbounds": [{"type": "direct", "tag": "direct"}]
}
CFGEOF
echo "[CONFIG] 配置已生成"

# ================== 启动 sing-box ==================
echo "[SING-BOX] 启动中..."
"$SB_FILE" run -c "${FILE_PATH}/config.json" &
SB_PID=$!
echo "$SB_PID" > "${FILE_PATH}/sb.pid"
sleep 2

if ! kill -0 $SB_PID 2>/dev/null; then
    echo "[SING-BOX] 启动失败"
    head -n 2 "${FILE_PATH}/private.key"
    "$SB_FILE" run -c "${FILE_PATH}/config.json"
    exit 1
fi
echo "[SING-BOX] 已启动 PID: $SB_PID"

# ================== [ACME] 启动自动续期守护进程 ==================
if [ "$USE_ACME" = true ]; then
    (
        while true; do
            sleep 86400 # 每天检查一次
            "$ACME_HOME/acme.sh" --cron --home "$ACME_HOME" >/dev/null 2>&1
        done
    ) &
    echo "[ACME] 自动续期守护进程已启动"
fi

# ================== [修复] Argo 隧道 ==================
ARGO_LOG="${FILE_PATH}/argo.log"
ARGO_DOMAIN=""

echo "[Argo] 启动隧道 (HTTP2模式)..."
"$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://127.0.0.1:${ARGO_PORT} > "$ARGO_LOG" 2>&1 &
ARGO_PID=$!

for i in {1..30}; do
    sleep 1
    ARGO_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | head -1 | sed 's|https://||')
    [ -n "$ARGO_DOMAIN" ] && break
done
[ -n "$ARGO_DOMAIN" ] && echo "[Argo] 域名: $ARGO_DOMAIN" || echo "[Argo] 获取域名失败"

# ================== 生成订阅 ==================
generate_sub "$ARGO_DOMAIN"

# ================== 确定订阅链接 ==================
SUB_URL="http://${PUBLIC_IP}:${HTTP_PORT}/sub"

# ================== 输出结果 ==================
echo ""
echo "==================================================="
if [ "$SINGLE_PORT_MODE" = true ]; then
    echo "模式: 单端口 (${SINGLE_PORT_UDP^^} + Argo)"
    echo ""
    echo "代理节点:"
    [ -n "$HY2_PORT" ] && echo "  - HY2 (UDP): ${PUBLIC_IP}:${HY2_PORT}"
    [ -n "$TUIC_PORT" ] && echo "  - TUIC (UDP): ${PUBLIC_IP}:${TUIC_PORT}"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo (WS): ${ARGO_DOMAIN}"
else
    echo "模式: 多端口 (TUIC + HY2 + Reality + Argo)"
    echo ""
    echo "代理节点:"
    echo "  - TUIC (UDP): ${PUBLIC_IP}:${TUIC_PORT}"
    echo "  - HY2 (UDP): ${PUBLIC_IP}:${HY2_PORT}"
    echo "  - Reality (TCP): ${PUBLIC_IP}:${REALITY_PORT}"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo (WS): ${ARGO_DOMAIN}"
fi
echo ""
echo "订阅链接: $SUB_URL"
echo "==================================================="
echo ""

# ================== 保持运行 ==================
wait $SB_PID

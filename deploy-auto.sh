#!/bin/bash

# ========= [接收 Socks5 参数] =========
S5_IP="$1"
S5_PORT="$2"
S5_USER="$3"
S5_PASS="$4"

if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo -e "\n❌ 参数缺失！请使用以下格式："
  echo "bash <(curl -Ls https://raw.githubusercontent.com/TombRaider001/deploy-node/main/deploy-auto.sh) \\"
  echo "     [ip] [端口] [用户名] [密码]"
  echo "例如：38.135.189.160 35148 iQ8aJ8 kV6oW2"
  exit 1
fi

# ========= [基本配置] =========
BASE_DOMAIN="wdch.moneylll.top"
SUB_DOMAIN="wdch-$(date +%s)"
FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
VPS_IP=$(curl -s ipv4.ip.sb)
XUI_PORT="10000"

# ========= [开启 BBR + TCP 优化] =========
echo -e "\n⚙️ 配置 BBR 加速和 TCP 优化..."
cat >> /etc/sysctl.conf <<EOF
# TCP 缓冲优化
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096

# 启用 BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 性能增强
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0

# 可选：反向路径检查关闭（适合中转）
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
EOF
sysctl -p

# ========= [安装依赖] =========
echo -e "\n📦 安装必要依赖..."
apt update && apt install curl wget socat jq -y

# ========= [添加 Cloudflare DNS 解析] =========
echo -e "\n🌐 添加 Cloudflare DNS 解析..."
CF_API="olBJjXHXh041-il-3Yw6BcuM2ZwafjjQgY4Hkqyc"
CF_EMAIL="fangdashi6688@gmail.com"

CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
  --data '{"type":"A","name":"'${SUB_DOMAIN}'","content":"'${VPS_IP}'","ttl":120,"proxied":false}' >/dev/null

echo "$VPS_IP $FULL_DOMAIN" >> /etc/hosts

# ========= [安装 3x-ui] =========
echo -e "\n🚀 安装 3x-ui..."
INSTALL_LOG=$(bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}")

# 解析面板信息
XUI_USER=$(echo "$INSTALL_LOG" | grep -oP "Username:\s*\K.*")
XUI_PASS=$(echo "$INSTALL_LOG" | grep -oP "Password:\s*\K.*")
XUI_PATH=$(echo "$INSTALL_LOG" | grep -oP "WebBasePath:\s*\K.*")
[[ -z "$XUI_PATH" || "$XUI_PATH" == "/" ]] && XUI_PATH=""
XUI_URL="http://${VPS_IP}:${XUI_PORT}${XUI_PATH}"

# ========= [申请 TLS 证书] =========
echo -e "\n🔐 申请 TLS 证书..."
curl https://get.acme.sh | sh
export CF_Token="$CF_API"
export CF_Email="$CF_EMAIL"
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue --dns dns_cf -d $FULL_DOMAIN --keylength ec-256 --force
~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
  --key-file /etc/x-ui/server.key \
  --fullchain-file /etc/x-ui/server.crt

# ========= [输出信息] =========
echo -e "\n✅ 节点部署完成！以下是详细信息："
echo "------------------------------------------"
echo "📍 面板地址：$XUI_URL"
echo "👤 用户名：$XUI_USER"
echo "🔑 密码：$XUI_PASS"
echo ""
echo "🔁 入站建议：Vmess/Vless + TCP + TLS + $FULL_DOMAIN"
echo "🌐 出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS"
echo "📄 证书路径 (CRT)：/etc/x-ui/server.crt"
echo "🔐 证书密钥 (KEY)：/etc/x-ui/server.key"
echo "------------------------------------------"
echo "✅ BBR 加速已开启"

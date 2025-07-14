#!/bin/bash

# ========= [接收 Socks5 参数] =========
S5_IP="$1"
S5_PORT="$2"
S5_USER="$3"
S5_PASS="$4"

# 检查参数
if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo -e "\n❌ 参数缺失！请使用格式："
  echo "bash <(curl -Ls https://raw.githubusercontent.com/TombRaider001/deploy-node/main/deploy-auto.sh) \\
     [ip] [端口] [用户名] [密码]"
  echo "例如：38.135.189.160 35148 iQ8aJ8 kV6oW2"
  exit 1
fi

# ========= [基本配置] =========
BASE_DOMAIN="wdch.moneylll.top"
SUB_DOMAIN="wdch-$(date +%s)"
FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
VPS_IP=$(curl -s ipv4.ip.sb)
XUI_PORT="10000"

# ========= [开启 BBR 加速] =========
echo -e "\n⚙️ 配置 BBR 加速..."
cat >> /etc/sysctl.conf <<EOF
# TCP 优化
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096

# 拥塑控制与队列调度
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 加速项
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3

# 邻居发现优化
net.ipv4.neigh.default.base_reachable_time_ms = 600000
net.ipv4.neigh.default.mcast_solicit = 20
net.ipv4.neigh.default.retrans_time_ms = 250

# 关闭反向路径检查
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
net.ipv4.conf.eth1.rp_filter = 0
EOF
sysctl -p

# ========= [安装依赖] =========
echo -e "\n🔧 安装依赖中..."
apt update && apt install curl wget unzip vim sqlite3 socat cron -y

# ========= [解析域名写入 hosts] =========
echo "$VPS_IP $FULL_DOMAIN" >> /etc/hosts

# ========= [自动 DNS 解析到当前 IP] =========
echo -e "\n🌐 添加 Cloudflare DNS 解析..."
CF_API="olBJjXHXh041-il-3Yw6BcuM2ZwafjjQgY4Hkqyc"
CF_EMAIL="fangdashi6688@gmail.com"
CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "X-Auth-Email: $CF_EMAIL" -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "X-Auth-Email: $CF_EMAIL" \
  -H "Authorization: Bearer $CF_API" \
  -H "Content-Type: application/json" \
  --data '{"type":"A","name":"'${SUB_DOMAIN}'","content":"'${VPS_IP}'","ttl":120,"proxied":false}' >/dev/null

# ========= [申请证书] =========
echo -e "\n📜 申请 TLS 证书（使用 standalone 模式）..."
curl https://get.acme.sh | sh
apt install socat -y || yum install socat -y

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

~/.acme.sh/acme.sh --issue -d $FULL_DOMAIN --standalone -k ec-256 --force --insecure

~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
  --key-file /etc/x-ui/server.key \
  --fullchain-file /etc/x-ui/server.crt

# ========= [安装 3x-ui 并读取随机信息] =========
echo -e "\n📦 安装 3x-ui 中..."
INSTALL_LOG=$(bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}")

# 提取用户名、密码、WebPath
XUI_USER=$(echo "$INSTALL_LOG" | grep -oP "Username:\s*\K.*")
XUI_PASS=$(echo "$INSTALL_LOG" | grep -oP "Password:\s*\K.*")
XUI_PATH=$(echo "$INSTALL_LOG" | grep -oP "WebBasePath:\s*\K.*")
[[ -z "$XUI_PATH" || "$XUI_PATH" == "/" ]] && XUI_PATH=""
XUI_URL="http://${VPS_IP}:${XUI_PORT}${XUI_PATH}"

# ========= [输出信息] =========
echo -e "\n✅ 节点部署完成！以下是详细信息："
echo "------------------------------------------"
echo "🌐 面板地址：$XUI_URL"
echo "👤 用户名：$XUI_USER"
echo "🔐 密码：$XUI_PASS"
echo ""
echo "🛈 入站建议：Vmess/Vless + TCP + TLS + $FULL_DOMAIN"
echo "🚪 出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS"
echo "📜 证书路径（CRT）：/etc/x-ui/server.crt"
echo "🔐 证书密钥（KEY）：/etc/x-ui/server.key"
echo "------------------------------------------"
echo "🚀 BBR 加速已开启"


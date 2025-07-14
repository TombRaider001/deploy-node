#!/bin/bash

# ========= [接收 Socks5 参数] =========
S5_IP="$1"
S5_PORT="$2"
S5_USER="$3"
S5_PASS="$4"

# ========= [检查参数] =========
if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo -e "\n❌ 参数缺失！请使用格式："
  echo "bash <(curl -Ls https://raw.githubusercontent.com/TombRaider001/deploy-node/main/deploy-vmess-auto.sh) \\
     [ip] [端口] [用户名] [密码]"
  echo "例如：38.135.189.160 35148 iQ8aJ8 kV6oW2"
  exit 1
fi

# ========= [基本配置] =========
DOMAIN="moneylll.top"
BASE_DOMAIN="wdch.$DOMAIN"
SUB_DOMAIN="wdch-$(date +%s)"
FULL_DOMAIN="$SUB_DOMAIN.$BASE_DOMAIN"
VPS_IP=$(curl -s ipv4.ip.sb)
XUI_PORT="10000"
EMAIL="fangdashi6688@gmail.com"
CF_API="olBJjXHXh041-il-3Yw6BcuM2ZwafjjQgY4Hkqyc"

# ========= [安装依赖与 TCP 优化] =========
echo -e "\n🔧 安装依赖与开启 BBR..."
apt update && apt install curl wget unzip vim sqlite3 socat cron -y

cat >> /etc/sysctl.conf <<EOF
# TCP 优化
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.neigh.default.base_reachable_time_ms = 600000
net.ipv4.neigh.default.mcast_solicit = 20
net.ipv4.neigh.default.retrans_time_ms = 250
net.ipv4.neigh.eth0.delay_first_probe_time = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
EOF
sysctl -p

# ========= [配置 acme.sh 环境变量并申请证书] =========
echo -e "\n📜 开始申请证书：$FULL_DOMAIN"
export CF_Token="$CF_API"
export CF_Account_ID=""
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$FULL_DOMAIN" --keylength ec-256 --accountemail $EMAIL
~/.acme.sh/acme.sh --install-cert -d "$FULL_DOMAIN" --ecc \
--fullchain-file /etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem \
--key-file /etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem

# ========= [写入 hosts] =========
echo "$VPS_IP $FULL_DOMAIN" >> /etc/hosts

# ========= [安装 3x-ui 到固定端口] =========
echo -e "\n📦 安装 3x-ui 面板..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}"

sleep 2
DB="/etc/x-ui/x-ui.db"
XUI_USER="wdch"
XUI_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 10)
HASHED_PASS=$(/usr/bin/x-ui hash "$XUI_PASS")
sqlite3 $DB "DELETE FROM users;"
sqlite3 $DB "INSERT INTO users (username, password) VALUES ('$XUI_USER', '$HASHED_PASS');"
XUI_PATH=$(sqlite3 $DB "SELECT value FROM settings WHERE key = 'web_path' LIMIT 1;")
[[ "$XUI_PATH" == "/" || -z "$XUI_PATH" ]] && XUI_PATH=""
XUI_URL="http://$VPS_IP:$XUI_PORT$XUI_PATH"

# ========= [添加证书续签定时任务] =========
(crontab -l 2>/dev/null; echo "0 3 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null") | crontab -

# ========= [输出部署信息] =========
echo -e "\n✅ 节点部署完成！以下是详细信息："
echo "------------------------------------------"
echo "🌐 面板地址：$XUI_URL"
echo "👤 用户名：$XUI_USER"
echo "🔐 密码：$XUI_PASS"
echo "📜 证书路径："
echo "    证书：/etc/letsencrypt/live/$FULL_DOMAIN/fullchain.pem"
echo "    私钥：/etc/letsencrypt/live/$FULL_DOMAIN/privkey.pem"
echo "🛰 入站建议：Vmess + TLS + $FULL_DOMAIN"
echo "🚪 出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS"
echo "📶 TCP 加速：BBR 已启用"
echo "------------------------------------------"

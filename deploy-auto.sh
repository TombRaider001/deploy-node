#!/bin/bash

# ========= [接收 Socks5 参数] =========
S5_IP="$1"
S5_PORT="$2"
S5_USER="$3"
S5_PASS="$4"

# 检查参数
if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo -e "\n参数缺失！请使用格式："
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
echo -e "\n配置 BBR 加速..."
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p

# ========= [安装依赖] =========
echo -e "\n安装依赖..."
apt update && apt install curl wget unzip vim sqlite3 socat cron jq -y

# ========= [自动 DNS 添加记录] =========
echo -e "\n配置 DNS 解析..."
CF_API="olBJjXHXh041-il-3Yw6BcuM2ZwafjjQgY4Hkqyc"
CF_EMAIL="fangdashi6688@gmail.com"
CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "X-Auth-Email: $CF_EMAIL" -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
  -H "X-Auth-Email: $CF_EMAIL" \
  -H "Authorization: Bearer $CF_API" \
  -H "Content-Type: application/json" \
  --data '{"type":"A","name":"'${SUB_DOMAIN}'","content":"'${VPS_IP}'","ttl":120,"proxied":false}' > /dev/null

# ========= [安装 X-UI] =========
echo -e "\n安装 3x-ui..."
INSTALL_LOG=$(bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}")

XUI_USER=$(echo "$INSTALL_LOG" | grep -oP "Username:\s*\K.*")
XUI_PASS=$(echo "$INSTALL_LOG" | grep -oP "Password:\s*\K.*")
XUI_PATH=$(echo "$INSTALL_LOG" | grep -oP "WebBasePath:\s*\K.*")
[[ -z "$XUI_PATH" || "$XUI_PATH" == "/" ]] && XUI_PATH=""
XUI_URL="http://${VPS_IP}:${XUI_PORT}${XUI_PATH}"

# ========= [申请 TLS 证书 - DNS 模式] =========
echo -e "\n申请 TLS 证书..."
curl https://get.acme.sh | sh
export CF_Token="$CF_API"
export CF_Email="$CF_EMAIL"
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue --dns dns_cf -d $FULL_DOMAIN -k ec-256 --force
~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
  --key-file /etc/x-ui/server.key \
  --fullchain-file /etc/x-ui/server.crt

# ========= [输出信息] =========
echo -e "\n节点部署完成！ 详情如下："
echo "------------------------------------------"
echo "面板地址：$XUI_URL"
echo "用户名：$XUI_USER"
echo "密码：$XUI_PASS"
echo ""
echo "入站建议：Vmess/Vless + TCP + TLS + $FULL_DOMAIN"
echo "出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS"
echo "证书路径 (CRT)：/etc/x-ui/server.crt"
echo "证书密钥 (KEY)：/etc/x-ui/server.key"
echo "------------------------------------------"
echo "BBR 加速已启用"

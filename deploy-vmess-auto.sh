#!/bin/bash

# ========= [接收 Socks5 参数] =========
S5_IP="$1"
S5_PORT="$2"
S5_USER="$3"
S5_PASS="$4"

# 检查参数
if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo -e "\n❌ 参数缺失！请使用格式："
  echo "bash <(curl -Ls https://raw.githubusercontent.com/TombRaider001/deploy-node/main/deploy-vmess-auto.sh) \\"
  echo "     38.135.189.160 35148 iQ8aJ8 kV6oW2"
  exit 1
fi

# ========= [基本配置] =========
BASE_DOMAIN="wdch.moneylll.top"
SUB_DOMAIN="wdch-$(date +%s)"
FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
VPS_IP=$(curl -s ipv4.ip.sb)

# ========= [安装依赖] =========
echo -e "\n🔧 安装依赖中..."
apt update && apt install curl wget unzip vim -y

# ========= [解析域名写入 hosts] =========
echo "$VPS_IP $FULL_DOMAIN" >> /etc/hosts

# ========= [安装 3X-UI 到端口 10000] =========
echo -e "\n📦 安装 3x-ui 中..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
10000
"

# ========= [等待写入数据库完成] =========
sleep 2

# ========= [提取信息并输出] =========
DB="/etc/x-ui/x-ui.db"

# 获取信息（x-ui v2 结构）
XUI_PORT=$(sqlite3 $DB "SELECT panel_port FROM settings LIMIT 1;")
XUI_USER=$(sqlite3 $DB "SELECT username FROM users LIMIT 1;")
XUI_PASS=$(sqlite3 $DB "SELECT password FROM users LIMIT 1;")
XUI_PATH=$(sqlite3 $DB "SELECT web_base_path FROM settings LIMIT 1;")

[[ -z "$XUI_PATH" || "$XUI_PATH" == "/" ]] && XUI_PATH=""

XUI_URL="http://${VPS_IP}:${XUI_PORT}${XUI_PATH}"

# ========= [输出信息] =========
echo -e "\n✅ 节点部署完成！以下是详细信息："
echo "------------------------------------------"
echo "🌐 面板地址：$XUI_URL"
echo "👤 用户名：$XUI_USER"
echo "🔐 密码：$XUI_PASS"
echo ""
echo "🛰 入站建议：Vmess + TLS + $FULL_DOMAIN"
echo "🚪 出站 Socks5：$S5_IP:$S5_PORT @ $S5_USER/$S5_PASS"
echo "------------------------------------------"

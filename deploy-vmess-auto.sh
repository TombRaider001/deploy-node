#!/bin/bash

# ==== 默认值（可省略参数使用） ====
S5_IP=""
S5_PORT=""
S5_USER=""
S5_PASS=""

# ==== 解析参数 ====
for arg in "$@"
do
  case $arg in
    --s5ip=*)   S5_IP="${arg#*=}" ;;
    --s5port=*) S5_PORT="${arg#*=}" ;;
    --s5user=*) S5_USER="${arg#*=}" ;;
    --s5pass=*) S5_PASS="${arg#*=}" ;;
  esac
done

# ==== 检查参数 ====
if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo "❌ 参数不完整！用法示例："
  echo "bash <(curl -Ls https://raw.githubusercontent.com/你/仓库/main/deploy.sh) \\"
  echo "  --s5ip=1.2.3.4 --s5port=1080 --s5user=test --s5pass=123456"
  exit 1
fi

# ==== 自动域名生成 ====
BASE_DOMAIN="wdch.moneylll.top"
TIMESTAMP=$(date +%s)
SUB_DOMAIN="wdch-$TIMESTAMP"
FULL_DOMAIN="$SUB_DOMAIN.$BASE_DOMAIN"
VPS_IP=$(curl -s ipv4.ip.sb)

# ==== 安装工具 ====
apt update && apt install -y curl wget vim unzip ufw lsof

# ==== hosts 绑定 ====
echo "$VPS_IP $FULL_DOMAIN" >> /etc/hosts

# ==== 安装 3X-UI ====
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
10000
EOF

sleep 3

# ==== 提取登录信息 ====
CONFIG_PATH="/etc/x-ui/config.json"
if [ -f "$CONFIG_PATH" ]; then
  PANEL_USER=$(grep -oP '(?<="username": ")[^"]*' "$CONFIG_PATH")
  PANEL_PASS=$(grep -oP '(?<="password": ")[^"]*' "$CONFIG_PATH")
  WEB_PATH=$(grep -oP '(?<="web_base_path": ")[^"]*' "$CONFIG_PATH")
else
  PANEL_USER="admin"
  PANEL_PASS="123456"
  WEB_PATH=""
fi

# ==== 输出信息 ====
echo ""
echo "✅ 部署完成！以下是详细信息："
echo "------------------------------------------"
echo "🌐 面板地址：http://$VPS_IP:10000/$WEB_PATH"
echo "👤 用户名：$PANEL_USER"
echo "🔐 密码：$PANEL_PASS"
echo ""
echo "📡 节点域名：$FULL_DOMAIN"
echo "➡️ Socks5 出口：$S5_IP:$S5_PORT"
echo "   用户名：$S5_USER"
echo "   密码：$S5_PASS"
echo "------------------------------------------"

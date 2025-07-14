#!/bin/bash

# =========【用户可通过参数自定义 Socks5 配置】==========

for arg in "$@"; do
  case $arg in
    --s5ip=*) S5_IP="${arg#*=}" ;;
    --s5port=*) S5_PORT="${arg#*=}" ;;
    --s5user=*) S5_USER="${arg#*=}" ;;
    --s5pass=*) S5_PASS="${arg#*=}" ;;
  esac
  shift
done

# 如果没有传参，使用默认值
S5_IP=${S5_IP:-"127.0.0.1"}
S5_PORT=${S5_PORT:-"1080"}
S5_USER=${S5_USER:-"user"}
S5_PASS=${S5_PASS:-"pass"}

# ✅ 自动生成唯一子域名（用时间戳）
TIMESTAMP=$(date +%s)
SUB_DOMAIN="wdch-$TIMESTAMP"
BASE_DOMAIN="wdch.moneylll.top"
FULL_DOMAIN="$SUB_DOMAIN.$BASE_DOMAIN"

# ✅ 获取 VPS 公网 IP
VPS_IP=$(curl -s ipv4.ip.sb)

# ✅ 更新系统 & 安装依赖
apt update && apt install curl wget vim unzip ufw sqlite3 -y

# ✅ 添加 hosts 解析
echo "$VPS_IP $FULL_DOMAIN" >> /etc/hosts

# ✅ 安装 3X-UI
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# ✅ 等待服务启动
sleep 3

# ✅ 提取 3X-UI 登录信息
DB="/etc/x-ui/x-ui.db"
if [ -f "$DB" ]; then
  LOGIN_INFO=$(sqlite3 $DB "SELECT username, password FROM users LIMIT 1;")
  PORT=$(sqlite3 $DB "SELECT port FROM settings LIMIT 1;")
  PATH=$(sqlite3 $DB "SELECT web_base_path FROM settings LIMIT 1;")

  USERNAME=$(echo "$LOGIN_INFO" | cut -d'|' -f1)
  PASSWORD=$(echo "$LOGIN_INFO" | cut -d'|' -f2)

  echo ""
  echo "✅ 部署完成！以下是详细信息："
  echo "------------------------------------------"
  echo "🌐 面板地址：http://$VPS_IP:$PORT/$PATH"
  echo "👤 用户名：$USERNAME"
  echo "🔐 密码：$PASSWORD"
  echo "📥 入站建议：Vmess + TLS + $FULL_DOMAIN"
  echo "📤 出站建议：Socks5 ($S5_IP:$S5_PORT @ $S5_USER/$S5_PASS)"
  echo "------------------------------------------"
else
  echo "❌ 提取失败：找不到数据库文件 $DB"
fi

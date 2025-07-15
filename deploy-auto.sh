#!/bin/bash

# 检查是否用 bash
if [ -z "$BASH_VERSION" ]; then
  echo -e "\033[31m[ERR] 请用 bash 执行本脚本！（不要用 sh 或 dash）\033[0m"
  exit 1
fi

# 日志与输出文件
LOG_DIR="/root/xui-info"
mkdir -p "$LOG_DIR"
LAST_LOG="$LOG_DIR/last_run.log"
ERR_LOG="$LOG_DIR/error.log"
INFO_FILE="" # 稍后赋值

# 颜色变量
RED='\033[31m'
GRN='\033[32m'
YEL='\033[33m'
CYN='\033[36m'
NC='\033[0m'

# 发行版适配
PM=""
if command -v apt >/dev/null 2>&1; then
  PM="apt"
  update_cmd="apt update && apt -y upgrade"
  install_cmd="apt install -y"
elif command -v yum >/dev/null 2>&1; then
  PM="yum"
  update_cmd="yum -y update"
  install_cmd="yum install -y"
else
  echo -e "${RED}[ERR] 暂不支持你的 Linux 发行版！${NC}"
  exit 1
fi

echo -e "${CYN}[INFO]${NC} 正在升级系统包&检测依赖..."
DEBIAN_FRONTEND=noninteractive $update_cmd

for cmd in curl jq socat wget dig; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo -e "${YEL}[INFO]${NC} 缺少 $cmd，自动安装中..."
    DEBIAN_FRONTEND=noninteractive $install_cmd $cmd
  fi
done

# 参数校验
S5_IP="$1"
S5_PORT="$2"
S5_USER="$3"
S5_PASS="$4"

if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
  echo -e "\n${RED}❌ 参数缺失！请使用格式：${NC}"
  echo "bash <(curl -Ls https://raw.githubusercontent.com/TombRaider001/deploy-node/main/deploy-auto.sh) [ip] [端口] [用户名] [密码]"
  exit 1
fi

# 变量定义
BASE_DOMAIN="moneylll.top"
TIME_STR=$(date +%Y%m%d%H%M)
SUB_DOMAIN="wdch-${TIME_STR}.wdch"
FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
INFO_FILE="$LOG_DIR/${FULL_DOMAIN}.log"
XUI_PORT="10000"
VPS_IP=$(curl -s --max-time 10 ipv4.ip.sb || curl -s --max-time 10 ip.sb || hostname -I | awk '{print $1}')

CF_API="${CF_API:?请先 export CF_API=你的Token}"
CF_EMAIL="${CF_EMAIL:?请先 export CF_EMAIL=你的邮箱}"

# 日志重定向（全程保存）
exec > >(tee -a "$LAST_LOG") 2>>"$ERR_LOG"

# TCP/BBR 优化
if ! grep -q "net.ipv4.tcp_rmem" /etc/sysctl.conf; then
cat >> /etc/sysctl.conf <<EOF
# TCP 优化
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
  sysctl -p
fi

# Cloudflare DNS 解析
echo -e "${CYN}[INFO]${NC} 添加 Cloudflare 解析..."
grep -q "CF_Token" /root/.bashrc || echo "export CF_Token='$CF_API'" >> /root/.bashrc
grep -q "CF_Email" /root/.bashrc || echo "export CF_Email='$CF_EMAIL'" >> /root/.bashrc
export CF_Token="$CF_API"
export CF_Email="$CF_EMAIL"

CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
  -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')

if [[ -z "$CF_ZONE" || "$CF_ZONE" == "null" ]]; then
  echo -e "${RED}[ERR] Cloudflare Zone ID 获取失败！${NC}"
  echo -e "${RED}请检查：\n- BASE_DOMAIN 填写是否正确\n- CF_API Token 权限是否包含 Zone.DNS、Zone.Zone\n- Token 是否过期\n- Cloudflare 账号是否可用${NC}"
  exit 1
fi

# 添加/更新 A 记录，最多重试2次
try=0; ok=0
while [[ $try -lt 2 && $ok -eq 0 ]]; do
  REC_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?name=${FULL_DOMAIN}" \
    -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')
  if [[ $REC_ID == "null" || -z $REC_ID ]]; then
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
      -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'${SUB_DOMAIN}'","content":"'${VPS_IP}'","ttl":120,"proxied":false}' >/dev/null
  else
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records/$REC_ID" \
      -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" \
      --data '{"type":"A","name":"'${SUB_DOMAIN}'","content":"'${VPS_IP}'","ttl":120,"proxied":false}' >/dev/null
  fi
  sleep 5
  DNS_IP=$(dig +short $FULL_DOMAIN | grep -E '^[0-9.]+' | head -1)
  if [[ "$DNS_IP" == "$VPS_IP" ]]; then ok=1; break; fi
  try=$((try+1))
  echo -e "${YEL}[WARN] 第${try}次DNS生效检测失败，重试...${NC}"
done

if [[ $ok -eq 0 ]]; then
  echo -e "${RED}[ERR] DNS 解析未能生效，请检查Cloudflare状态/VPS IP！${NC}"
  exit 1
fi

# 3x-ui 安装/检测
if [[ ! -d "/etc/x-ui" ]]; then
  echo -e "${CYN}[INFO]${NC} 安装 3x-ui 面板..."
  INSTALL_LOG=$(bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}")
else
  echo -e "${YEL}[WARN] 检测到3x-ui已安装，跳过安装。${NC}"
  INSTALL_LOG=$(x-ui info)
fi

XUI_USER=$(echo "$INSTALL_LOG" | grep -oP "Username:\s*\K.*" | head -1)
XUI_PASS=$(echo "$INSTALL_LOG" | grep -oP "Password:\s*\K.*" | head -1)
XUI_PATH=$(echo "$INSTALL_LOG" | grep -oP "WebBasePath:\s*\K.*" | head -1)
XUI_PATH="${XUI_PATH#/}"

# acme.sh 证书自动申请
echo -e "${CYN}[INFO]${NC} 正在申请SSL证书..."

curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
ACME_OUT=$(
~/.acme.sh/acme.sh --issue --dns dns_cf -d $FULL_DOMAIN --keylength ec-256 --force 2>&1
)
if ! echo "$ACME_OUT" | grep -q "Your cert is in"; then
  echo -e "\n${RED}[ERR] 证书签发失败！${NC}\n----acme.sh输出信息如下----"
  echo -e "${RED}$ACME_OUT${NC}"
  echo -e "\n${YEL}[常见原因]${NC}\n1. Cloudflare Token无权管理该子域名\n2. DNS解析未生效/被污染\n3. VPS网络到acme服务器不通\n4. Token使用频率超限\n5. 请尝试重新export参数和再重试"
  exit 1
fi

~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
  --key-file /etc/x-ui/server.key \
  --fullchain-file /etc/x-ui/server.crt

# 输出&保存信息
{
  echo -e "${GRN}面板地址（IP直连）：http://${VPS_IP}:${XUI_PORT}/${XUI_PATH}${NC}"
  echo "面板地址（域名访问）：http://${FULL_DOMAIN}:${XUI_PORT}/${XUI_PATH}"
  echo -e "${GRN}用户名：$XUI_USER${NC}"
  echo -e "${GRN}密码：$XUI_PASS${NC}"
  echo ""
  echo -e "${GRN}入站建议：Vmess/Vless + TCP + TLS + $FULL_DOMAIN${NC}"
  echo -e "${GRN}出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS${NC}"
  echo -e "${GRN}证书路径 (CRT)：/etc/x-ui/server.crt${NC}"
  echo -e "${GRN}证书密钥 (KEY)：/etc/x-ui/server.key${NC}"
  echo "------------------------------------------"
  echo -e "BBR 加速已开启"
  echo -e "证书已开启自动续签，无需手动干预"
} | tee "$INFO_FILE"

echo -e "${CYN}关键信息保存路径：$INFO_FILE${NC}"
echo -e "${CYN}本次运行所有输出日志：$LAST_LOG${NC}"
echo -e "${CYN}本次运行错误日志：$ERR_LOG${NC}"


#!/bin/bash

# 必须 bash
if [ -z "$BASH_VERSION" ]; then
  echo -e "\033[31m[ERR] 请用 bash 执行本脚本！（不要用 sh 或 dash）\033[0m"
  exit 1
fi

# 日志目录准备
LOG_DIR="/root/xui-info"
mkdir -p "$LOG_DIR"
LAST_LOG="$LOG_DIR/last_run.log"
ERR_LOG="$LOG_DIR/error.log"

# 彩色
RED='\033[31m'; GRN='\033[32m'; YEL='\033[33m'; CYN='\033[36m'; NC='\033[0m'

# 包管理器
if command -v apt >/dev/null 2>&1; then
  PM="apt"; update_cmd="apt update && apt -y upgrade"
  install_cmd="apt install -y"
elif command -v yum >/dev/null 2>&1; then
  PM="yum"; update_cmd="yum -y update"
  install_cmd="yum install -y"
else
  echo -e "${RED}[ERR] 暂不支持你的 Linux 发行版！${NC}"; exit 1
fi

# 依赖
echo -e "${CYN}[INFO]${NC} 正在升级系统包&检测依赖..."
DEBIAN_FRONTEND=noninteractive $update_cmd
for cmd in curl jq socat wget dig; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo -e "${YEL}[INFO]${NC} 缺少 $cmd，自动安装中..."
    DEBIAN_FRONTEND=noninteractive $install_cmd $cmd
  fi
done

# CF ENV
CF_API="${CF_API:?请先 export CF_API=你的Token}"
CF_EMAIL="${CF_EMAIL:?请先 export CF_EMAIL=你的邮箱}"

# ========== 参数判断 ==========
if (( $# % 2 != 0 )) || (( $# == 0 )); then
  echo -e "\n${RED}❌ 参数错误！每条必须“协议编号 S5参数”成对！${NC}"
  echo "例：1 38.106.2.221:35145:fA9aM4:Q5wA2 2 38.106.2.18:35145:fA9aM4:Q5wA2 ..."
  exit 1
fi

BATCH_COUNT=$(($#/2))
if (( BATCH_COUNT > 5 )); then
  echo -e "${YEL}[WARN]${NC} 一次最多只能申请 5 条（防止API超限），自动裁剪！"
  set -- "${@:1:10}"
  BATCH_COUNT=5
fi

BASE_DOMAIN="moneylll.top"
XUI_PORT="10000"
VPS_IP=$(curl -s --max-time 10 ipv4.ip.sb || curl -s --max-time 10 ip.sb || hostname -I | awk '{print $1}')
ALL_OUTPUT=""

# 重定向日志
exec > >(tee -a "$LAST_LOG") 2>>"$ERR_LOG"

# =================== 主循环 ===================
for ((i=1; i<=$#; i+=2)); do
  PROTO=${!i}
  S5_PARAM=${!((i+1))}
  # 检查 SOCKS5 参数格式
  IFS=':' read -r S5_IP S5_PORT S5_USER S5_PASS <<< "$S5_PARAM"
  if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
    echo -e "${RED}[ERR] 参数不全，跳过！${NC}"
    continue
  fi
  # 检查协议编号
  [[ "$PROTO" =~ ^[123]$ ]] || { echo -e "${RED}[ERR] 协议编号必须为 1/2/3，跳过！${NC}"; continue; }
  # 唯一性校验（避免重复 S5）
  KEY="${PROTO}_$S5_IP_$S5_PORT_$S5_USER_$S5_PASS"
  [[ " $S5_USED " =~ " $KEY " ]] && { echo -e "${YEL}[WARN] 重复S5已跳过：$S5_PARAM${NC}"; continue; }
  S5_USED+=" $KEY "

  # 随机子域&端口/ID
  TIME_STR=$(date +%Y%m%d%H%M%S)
  RAND_ID=$(( RANDOM % 10000 ))
  SUB_DOMAIN="wdch-${TIME_STR}${RAND_ID}.wdch"
  FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
  INFO_FILE="$LOG_DIR/${FULL_DOMAIN}.log"
  KEY_FILE="/etc/x-ui/${FULL_DOMAIN}.key"
  CRT_FILE="/etc/x-ui/${FULL_DOMAIN}.crt"

  # TCP/BBR 优化（只第一次）
  if ! grep -q "net.ipv4.tcp_rmem" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf <<EOF
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

  # ================= CF 解析 =================
  echo -e "${CYN}[INFO]${NC} 添加 Cloudflare 解析..."
  grep -q "CF_Token" /root/.bashrc || echo "export CF_Token='$CF_API'" >> /root/.bashrc
  grep -q "CF_Email" /root/.bashrc || echo "export CF_Email='$CF_EMAIL'" >> /root/.bashrc
  export CF_Token="$CF_API"; export CF_Email="$CF_EMAIL"

  CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
    -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')
  if [[ -z "$CF_ZONE" || "$CF_ZONE" == "null" ]]; then
    echo -e "${RED}[ERR] Cloudflare Zone ID 获取失败，跳过本条！${NC}"; continue
  fi

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
    echo -e "${RED}[ERR] DNS 解析未能生效，跳过本条！${NC}"; continue
  fi

  # 3x-ui 安装/检测
  if [[ ! -d "/etc/x-ui" ]]; then
    echo -e "${CYN}[INFO]${NC} 安装 3x-ui 面板..."
    INSTALL_LOG=$(bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}")
  else
    INSTALL_LOG=$(x-ui info)
  fi
  XUI_USER=$(echo "$INSTALL_LOG" | grep -oP "Username:\s*\K.*" | head -1)
  XUI_PASS=$(echo "$INSTALL_LOG" | grep -oP "Password:\s*\K.*" | head -1)
  XUI_PATH=$(echo "$INSTALL_LOG" | grep -oP "WebBasePath:\s*\K.*" | head -1)
  XUI_PATH="${XUI_PATH#/}"

  # 协议区分处理
  if [[ "$PROTO" == "3" ]]; then
    # ============ Shadowsocks ============
    SS_PORT=$((RANDOM % 20000 + 20000))
    SS_PASS=$(head -c 8 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
    SS_USER="ssuser$((RANDOM%10000))"
    # 加密方法默认 AES_128_GCM
    {
      echo -e "${GRN}面板地址（IP直连）：http://${VPS_IP}:${XUI_PORT}/${XUI_PATH}${NC}"
      echo "面板地址（域名访问）：http://${FULL_DOMAIN}:${XUI_PORT}/${XUI_PATH}"
      echo -e "${GRN}用户名：$XUI_USER${NC}"
      echo -e "${GRN}密码：$XUI_PASS${NC}"
      echo ""
      echo -e "${GRN}入站建议：Shadowsocks + TCP + $FULL_DOMAIN:$SS_PORT（密码:${SS_PASS}，加密:AES_128_GCM）${NC}"
      echo -e "${GRN}出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS${NC}"
      echo -e "${YEL}SS节点建议在面板自行添加（面板会随机端口/密码）${NC}"
      echo "------------------------------------------"
      echo -e "${GRN}BBR 加速已开启${NC}"
    } | tee "$INFO_FILE"
    ALL_OUTPUT+="\n\033[32m【SS】${FULL_DOMAIN}:${SS_PORT}  密码:${SS_PASS} 加密:AES_128_GCM${NC}\n"
    continue
  fi

  # ============ VLESS/VMESS =============
  # 证书（只给非ss分配）
  echo -e "${CYN}[INFO]${NC} 正在申请SSL证书..."
  curl https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ACME_OUT=$(
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d $FULL_DOMAIN --keylength ec-256 --force 2>&1
  )
  if ! echo "$ACME_OUT" | grep -q "Your cert is in"; then
    echo -e "\n${RED}[ERR] 证书签发失败！跳过本条！${NC}\n----acme.sh输出信息如下----"
    echo -e "${RED}$ACME_OUT${NC}"
    continue
  fi
  ~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CRT_FILE"

  # 自动生成 VLESS/VMESS 链接
  UUID=$(cat /proc/sys/kernel/random/uuid)
  IN_PORT=$((RANDOM%20000+20000))
  VM_PROTO_STR="vless"
  [[ "$PROTO" == "2" ]] && VM_PROTO_STR="vmess"
  VM_LINK="${VM_PROTO_STR}://${UUID}@${FULL_DOMAIN}:${IN_PORT}?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=${FULL_DOMAIN}#${FULL_DOMAIN}-socks5"

  # 输出
  {
    echo -e "${GRN}面板地址（IP直连）：http://${VPS_IP}:${XUI_PORT}/${XUI_PATH}${NC}"
    echo "面板地址（域名访问）：http://${FULL_DOMAIN}:${XUI_PORT}/${XUI_PATH}"
    echo -e "${GRN}用户名：$XUI_USER${NC}"
    echo -e "${GRN}密码：$XUI_PASS${NC}"
    echo ""
    echo -e "${GRN}入站建议：${VM_PROTO_STR^^} + TCP + TLS + $FULL_DOMAIN:$IN_PORT（UUID:${UUID}）${NC}"
    echo -e "${GRN}出站 Socks5：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS${NC}"
    echo -e "${GRN}证书路径 (CRT)：$CRT_FILE${NC}"
    echo -e "${GRN}证书密钥 (KEY)：$KEY_FILE${NC}"
    echo -e "${GRN}节点链接：${VM_LINK}${NC}"
    echo "------------------------------------------"
    echo -e "${GRN}BBR 加速已开启${NC}"
    echo -e "${GRN}证书已开启自动续签，无需手动干预${NC}"
  } | tee "$INFO_FILE"

  ALL_OUTPUT+="\n${VM_PROTO_STR^^}节点：${VM_LINK}\n"
done

echo -e "${CYN}全部任务已完成，关键信息见 /root/xui-info 目录。${NC}"
echo -e "${ALL_OUTPUT}"

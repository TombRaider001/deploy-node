#!/bin/bash

# ========== 颜色 ==========
RED='\033[31m'
GRN='\033[32m'
YEL='\033[33m'
CYN='\033[36m'
NC='\033[0m'

# ========== 依赖 ==========
LOG_DIR="/root/xui-info"
mkdir -p "$LOG_DIR"
LAST_LOG="$LOG_DIR/last_run.log"
ERR_LOG="$LOG_DIR/error.log"

# ========== 检查bash ==========
if [ -z "$BASH_VERSION" ]; then
  echo -e "${RED}[ERR] 请用 bash 执行本脚本！（不要用 sh 或 dash）${NC}"
  exit 1
fi

# ========== 包管理适配 ==========
if command -v apt >/dev/null 2>&1; then
  update_cmd="apt update && apt -y upgrade"
  install_cmd="apt install -y"
elif command -v yum >/dev/null 2>&1; then
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

# ========== 限制最多5条 ==========
MAX_BATCH=5
if (( $# > MAX_BATCH*2 )); then
  echo -e "${YEL}[WARN]${NC} 一次最多只能申请 $MAX_BATCH 条（防止API超限），只处理前${MAX_BATCH}条，其余自动跳过"
  set -- "${@:1:$((MAX_BATCH*2))}"
fi

# ========== 检查参数 ==========
if (( $# < 2 )); then
  echo -e "\n${RED}❌ 参数缺失！格式如下：${NC}"
  echo "bash deploy-auto-end.sh 协议编号 s5信息 [协议编号 s5信息 ...]"
  echo "示例: 1 38.1.2.3:10001:user:pass 2 38.1.2.4:10002:user:pass"
  exit 1
fi

# ========== 只允许1,2,3协议 ==========
PROTOS=("vless" "vmess" "ss")
BASE_DOMAIN="moneylll.top"
CF_API="${CF_API:?请先 export CF_API=你的Token}"
CF_EMAIL="${CF_EMAIL:?请先 export CF_EMAIL=你的邮箱}"

# ========== 重定向日志 ==========
exec > >(tee -a "$LAST_LOG") 2>>"$ERR_LOG"

# ========== 处理重复s5 ==========
declare -A s5_map
declare -A result_map

for ((i=1; i<=$#; i+=2)); do
  proto_idx="${!i}"
  s5_val="${!((i+1))}"
  if [[ "$s5_val" =~ ^[0-9.]+:[0-9]+:[^:]+:[^:]+$ ]]; then
    s5_map["$proto_idx-$s5_val"]=1
  fi
done

# ========== 主循环 ==========
idx=0
for ((i=1; i<=$#; i+=2)); do
  idx=$((idx+1))
  proto_idx="${!i}"
  s5_val="${!((i+1))}"

  # 协议判断
  [[ "$proto_idx" =~ ^[123]$ ]] || { echo -e "${RED}[ERR] 协议编号必须为1,2,3，跳过本条！${NC}"; continue; }
  proto="${PROTOS[$((proto_idx-1))]}"
  # s5格式判断
  if ! [[ "$s5_val" =~ ^[0-9.]+:[0-9]+:[^:]+:[^:]+$ ]]; then
    echo -e "${RED}[ERR] socks5格式错误：$s5_val 跳过本条！${NC}"; continue;
  fi

  # 检查重复
  key="${proto_idx}-${s5_val}"
  if [[ "${result_map[$key]}" == "1" ]]; then
    echo -e "${YEL}[WARN] 本条已存在，跳过重复s5：$s5_val ${NC}"; continue
  fi
  result_map[$key]=1

  S5_IP=$(echo "$s5_val" | cut -d: -f1)
  S5_PORT=$(echo "$s5_val" | cut -d: -f2)
  S5_USER=$(echo "$s5_val" | cut -d: -f3)
  S5_PASS=$(echo "$s5_val" | cut -d: -f4)

  TIME_STR=$(date +%Y%m%d%H%M%S)
  RAND_ID=$(( RANDOM % 10000 ))
  SUB_DOMAIN="wdch-${TIME_STR}${RAND_ID}.wdch"
  FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
  INFO_FILE="$LOG_DIR/${FULL_DOMAIN}.log"
  KEY_FILE="/etc/x-ui/${FULL_DOMAIN}.key"
  CRT_FILE="/etc/x-ui/${FULL_DOMAIN}.crt"
  XUI_PORT="10000"
  VPS_IP=$(curl -s --max-time 10 ipv4.ip.sb || curl -s --max-time 10 ip.sb || hostname -I | awk '{print $1}')

  # TCP/BBR优化（仅首次）
  if [[ $idx -eq 1 ]] && ! grep -q "net.ipv4.tcp_rmem" /etc/sysctl.conf; then
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

  # Cloudflare DNS
  echo -e "${CYN}[INFO]${NC} [${idx}] 添加 Cloudflare 解析..."
  CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
    -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')
  if [[ -z "$CF_ZONE" || "$CF_ZONE" == "null" ]]; then
    echo -e "${RED}[ERR] 获取CF Zone ID失败，跳过本条！${NC}"; continue
  fi
  # DNS记录
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
    # 等待DNS生效倒计时
    WAIT=30; echo -e "${YEL}[INFO] 等待DNS生效，倒计时${WAIT}秒...${NC}"
    for((sec=$WAIT; sec>0; sec--)); do echo -ne "\r${CYN}等待: $sec 秒${NC}   "; sleep 1; done; echo
    DNS_IP=$(dig +short $FULL_DOMAIN | grep -E '^[0-9.]+' | head -1)
    if [[ "$DNS_IP" == "$VPS_IP" ]]; then ok=1; break; fi
    try=$((try+1))
    echo -e "${YEL}[WARN] 第${try}次DNS生效检测失败，重试...${NC}"
  done
  if [[ $ok -eq 0 ]]; then
    echo -e "${RED}[ERR] DNS 解析未生效，跳过本条！${NC}"; continue
  fi

  # ========== ss类型不签发证书 ==========
  if [[ "$proto" == "ss" ]]; then
    SS_PORT=$((20000+RANDOM%30000))
    SS_USER=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)
    SS_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 22)
    # 输出信息
    {
      echo -e "${GRN}类型：Shadowsocks${NC}"
      echo -e "IP端口（监听）：${VPS_IP}:${SS_PORT}"
      echo -e "域名端口：${FULL_DOMAIN}:${SS_PORT}"
      echo -e "加密方式：AES_128_GCM"
      echo -e "用户：$SS_USER"
      echo -e "密码：$SS_PASS"
      sslink="ss://YWVzXzEyOF9nY206${SS_PASS}@${FULL_DOMAIN}:${SS_PORT}#auto-ss-${SS_PORT}"
      echo -e "链接：$sslink"
      echo "------------------------------------------"
      echo -e "${GRN}Socks5出口：${S5_IP}:${S5_PORT}:${S5_USER}:${S5_PASS}${NC}"
      echo "------------------------------------------"
    } | tee "$INFO_FILE"
    echo -e "${CYN}关键信息保存路径：$INFO_FILE${NC}"
    echo -e "${GRN}======================================================${NC}"
    continue
  fi

  # ========== vless/vmess证书 ==========
  echo -e "${CYN}[INFO]${NC} [${idx}] 证书API限流，等待20秒后申请..."
  for((sec=20; sec>0; sec--)); do echo -ne "\r${CYN}等待: $sec 秒${NC}   "; sleep 1; done; echo

  curl https://get.acme.sh | sh
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ACME_OUT=$(
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d $FULL_DOMAIN --keylength ec-256 --force 2>&1
  )
  if ! echo "$ACME_OUT" | grep -q "Your cert is in"; then
    echo -e "\n${RED}[ERR] 证书签发失败！跳过本条！${NC}\n----acme.sh输出如下----"
    echo -e "${RED}$ACME_OUT${NC}"
    continue
  fi
  ~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
    --key-file "$KEY_FILE" \
    --fullchain-file "$CRT_FILE"

  # ========== 随机端口与用户密码 ==========
  PORT=$((20000+RANDOM%30000))
  UUID=$(cat /proc/sys/kernel/random/uuid)
  USER=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)
  PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)
  # ======== 输出/保存信息 ========
  vmess_link=""; vless_link=""
  [[ "$proto" == "vless" ]] && vless_link="vless://${UUID}@${FULL_DOMAIN}:${PORT}?type=tcp&security=tls&sni=${FULL_DOMAIN}#auto-vless-${PORT}"
  [[ "$proto" == "vmess" ]] && vmess_link="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"auto-vmess-${PORT}\",\"add\":\"${FULL_DOMAIN}\",\"port\":\"${PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"tls\",\"sni\":\"${FULL_DOMAIN}\"}" | base64 -w0)"

  {
    echo -e "${GRN}类型：${proto^^}${NC}"
    echo -e "面板地址（IP直连）：http://${VPS_IP}:${XUI_PORT}/"
    echo -e "面板地址（域名访问）：http://${FULL_DOMAIN}:${XUI_PORT}/"
    echo -e "${GRN}UUID：$UUID${NC}"
    echo -e "${GRN}用户名：$USER${NC}"
    echo -e "${GRN}密码：$PASS${NC}"
    echo
    echo -e "${GRN}入站建议：${proto^^} + TCP + TLS + $FULL_DOMAIN${NC}"
    echo -e "${GRN}Socks5出口：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS${NC}"
    echo -e "${GRN}证书路径 (CRT)：$CRT_FILE${NC}"
    echo -e "${GRN}证书密钥 (KEY)：$KEY_FILE${NC}"
    echo "------------------------------------------"
    echo -e "${GRN}BBR 加速已开启${NC}"
    echo -e "${GRN}证书已开启自动续签，无需手动干预${NC}"
    [[ -n "$vless_link" ]] && echo -e "VLESS链接：$vless_link"
    [[ -n "$vmess_link" ]] && echo -e "VMESS链接：$vmess_link"
    echo "------------------------------------------"
  } | tee "$INFO_FILE"
  echo -e "${CYN}关键信息保存路径：$INFO_FILE${NC}"
  echo -e "${GRN}======================================================${NC}"

done

echo -e "${GRN}全部任务已完成，关键信息见 /root/xui-info 目录。${NC}"

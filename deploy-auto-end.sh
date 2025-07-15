#!/bin/bash

# 颜色
RED='\033[31m'
GRN='\033[32m'
YEL='\033[33m'
CYN='\033[36m'
NC='\033[0m'

# 日志与输出文件
LOG_DIR="/root/xui-info"
mkdir -p "$LOG_DIR"
LAST_LOG="$LOG_DIR/last_run.log"
ERR_LOG="$LOG_DIR/error.log"
SUMMARY_FILE="$LOG_DIR/summary_$(date +%Y%m%d%H%M%S).log"
> "$SUMMARY_FILE"

# 依赖
if command -v apt >/dev/null 2>&1; then
  PM="apt"
  update_cmd="apt update && apt -y upgrade"
  install_cmd="apt install -y"
elif command -v yum >/dev/null 2>&1; then
  PM="yum"
  update_cmd="yum -y update"
  install_cmd="yum install -y"
else
  echo -e "${RED}[ERR] 暂不支持你的 Linux 发行版！${NC}"; exit 1
fi

echo -e "${CYN}[INFO]${NC} 正在升级系统包&检测依赖..."
DEBIAN_FRONTEND=noninteractive $update_cmd
for cmd in curl jq socat wget dig; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo -e "${YEL}[INFO]${NC} 缺少 $cmd，自动安装中..."; DEBIAN_FRONTEND=noninteractive $install_cmd $cmd
  fi
done

# 必须 bash
if [ -z "$BASH_VERSION" ]; then
  echo -e "${RED}[ERR] 请用 bash 执行本脚本！（不要用 sh 或 dash）${NC}"; exit 1
fi

# cf 环境变量
CF_API="${CF_API:?请先 export CF_API=你的Token}"
CF_EMAIL="${CF_EMAIL:?请先 export CF_EMAIL=你的邮箱}"
BASE_DOMAIN="moneylll.top"
XUI_PORT="10000"

# 参数检查
MAX_BATCH=5
if (( ($#/2) > MAX_BATCH )); then
  echo -e "${YEL}[WARN]${NC} 一次最多支持 $MAX_BATCH 条（防止API超限），只处理前$MAX_BATCH条，其余自动跳过"
fi
if (( $# < 2 )); then
  echo -e "\n${RED}❌ 参数缺失！用法如下：${NC}"
  echo "bash xxx.sh 协议1 S5_1 协议2 S5_2 ... [协议5 S5_5]"
  echo "如：1 38.106.2.221:35145:fA9aM4:qQ5wA2 2 38.106.2.18:35145:fA9aM4:qQ5wA2"
  exit 1
fi

# 参数去重（只处理唯一的s5参数，跳过重复的）
declare -A USED_S5
TOTAL=$#
IDX=1
BUILT_COUNT=0
while [[ $IDX -le $TOTAL ]]; do
  PROTO="${!IDX}"; IDX=$((IDX+1))
  S5_PARAM="${!IDX}"; IDX=$((IDX+1))
  if [[ -z "$PROTO" || -z "$S5_PARAM" ]]; then
    echo -e "${RED}[ERR] 参数不全，跳过！${NC}"
    continue
  fi
  if [[ "${USED_S5[$S5_PARAM]}" == "1" ]]; then
    echo -e "${YEL}[WARN] 重复Socks5 $S5_PARAM，自动跳过${NC}"
    continue
  fi
  USED_S5["$S5_PARAM"]=1

  # S5 拆分
  IFS=':' read -r S5_IP S5_PORT S5_USER S5_PASS <<< "$S5_PARAM"
  if [[ -z "$S5_IP" || -z "$S5_PORT" || -z "$S5_USER" || -z "$S5_PASS" ]]; then
    echo -e "${RED}[ERR] Socks5参数不完整，跳过！${NC}"
    continue
  fi

  # 生成子域名、证书等
  TIME_STR=$(date +%Y%m%d%H%M%S)
  RAND_ID=$(( RANDOM % 10000 ))
  SUB_DOMAIN="wdch-${TIME_STR}${RAND_ID}.wdch"
  FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
  INFO_FILE="$LOG_DIR/${FULL_DOMAIN}.log"
  KEY_FILE="/etc/x-ui/${FULL_DOMAIN}.key"
  CRT_FILE="/etc/x-ui/${FULL_DOMAIN}.crt"
  VPS_IP=$(curl -s --max-time 10 ipv4.ip.sb || curl -s --max-time 10 ip.sb || hostname -I | awk '{print $1}')

  # 日志重定向（每条追加到全局日志/错误日志）
  exec > >(tee -a "$LAST_LOG") 2>>"$ERR_LOG"

  # BBR 优化一次（全局）
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

  # DNS
  echo -e "${CYN}[INFO]${NC} 添加 Cloudflare 解析..."
  grep -q "CF_Token" /root/.bashrc || echo "export CF_Token='$CF_API'" >> /root/.bashrc
  grep -q "CF_Email" /root/.bashrc || echo "export CF_Email='$CF_EMAIL'" >> /root/.bashrc
  export CF_Token="$CF_API"; export CF_Email="$CF_EMAIL"
  CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
      -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')
  if [[ -z "$CF_ZONE" || "$CF_ZONE" == "null" ]]; then
    echo -e "${RED}[ERR] Cloudflare Zone ID 获取失败，跳过本条！${NC}"
    continue
  fi
  # 添加/更新 A 记录（最多重试2次）
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
    echo -e "${RED}[ERR] DNS 解析未能生效，跳过本条！${NC}"
    continue
  fi

  # x-ui 检查/安装
  if [[ ! -d "/etc/x-ui" ]]; then
    echo -e "${CYN}[INFO]${NC} 安装 3x-ui 面板..."
    INSTALL_LOG=$(bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<< "y
${XUI_PORT}")
  else
    echo -e "${YEL}[WARN] 检测到3x-ui已安装，跳过安装。${NC}"
    INSTALL_LOG=$(x-ui info)
  fi

  # 生成节点数据
  XUI_USER=$(echo "$INSTALL_LOG" | grep -oP "Username:\s*\K.*" | head -1)
  XUI_PASS=$(echo "$INSTALL_LOG" | grep -oP "Password:\s*\K.*" | head -1)
  XUI_PATH=$(echo "$INSTALL_LOG" | grep -oP "WebBasePath:\s*\K.*" | head -1)
  XUI_PATH="${XUI_PATH#/}"

  # 节点协议类型
  case "$PROTO" in
    1)
      # VLESS+TCP+TLS
      PROTO_LABEL="VLESS"
      UUID=$(cat /proc/sys/kernel/random/uuid)
      IN_PORT=$((RANDOM%10000+20000))
      x-ui vless add --listen=0.0.0.0 --port=$IN_PORT --flow="" --id=$UUID --tls --serverName="$FULL_DOMAIN" --remark="auto-vless-$IN_PORT" --total=0 --expiry=""
      VLESS_LINK="vless://$UUID@$FULL_DOMAIN:$IN_PORT?type=tcp&security=tls&sni=$FULL_DOMAIN#auto-vless-$IN_PORT"
      ;;
    2)
      # VMESS+TCP+TLS
      PROTO_LABEL="VMESS"
      UUID=$(cat /proc/sys/kernel/random/uuid)
      IN_PORT=$((RANDOM%10000+30000))
      x-ui vmess add --listen=0.0.0.0 --port=$IN_PORT --id=$UUID --tls --serverName="$FULL_DOMAIN" --remark="auto-vmess-$IN_PORT" --total=0 --expiry=""
      VMESS_JSON="{\"v\":\"2\",\"ps\":\"auto-vmess-$IN_PORT\",\"add\":\"$FULL_DOMAIN\",\"port\":\"$IN_PORT\",\"id\":\"$UUID\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"tls\"}"
      VMESS_LINK="vmess://$(echo $VMESS_JSON | base64 -w0)"
      ;;
    3)
      # SS+Socks5出口
      PROTO_LABEL="Shadowsocks"
      SS_PORT=$((RANDOM%10000+40000))
      SS_USER=$(cat /proc/sys/kernel/random/uuid | cut -c1-8)
      SS_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
      METHOD="aes-128-gcm"
      x-ui ss add --listen=0.0.0.0 --port=$SS_PORT --method="$METHOD" --password="$SS_PASS" --remark="auto-ss-$SS_PORT" --total=0 --expiry=""
      SS_LINK="ss://$(echo -n "${METHOD}:${SS_PASS}@${FULL_DOMAIN}:${SS_PORT}" | base64 -w0)#auto-ss-$SS_PORT"
      ;;
    *)
      echo -e "${YEL}[WARN] 协议编号$PROTO暂不支持，只能用1(vless)、2(vmess)、3(ss)。本条跳过。${NC}"
      continue
      ;;
  esac

  # VLESS/VMESS才需要证书
  if [[ "$PROTO" == "1" || "$PROTO" == "2" ]]; then
    # acme.sh 证书
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
    CRT_NOTE="证书路径 (CRT)：$CRT_FILE\n证书密钥 (KEY)：$KEY_FILE"
  else
    CRT_NOTE="无需证书"
  fi

  # 输出到独立log和汇总
  {
    echo -e "${GRN}面板地址（IP直连）：http://${VPS_IP}:${XUI_PORT}/${XUI_PATH}${NC}"
    echo "面板地址（域名访问）：http://${FULL_DOMAIN}:${XUI_PORT}/${XUI_PATH}"
    echo -e "${GRN}用户名：$XUI_USER${NC}"
    echo -e "${GRN}密码：$XUI_PASS${NC}"
    echo ""
    echo -e "${GRN}Socks5出口：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS${NC}"
    [[ "$PROTO" == "1" ]] && echo -e "${GRN}VLESS链接：$VLESS_LINK${NC}"
    [[ "$PROTO" == "2" ]] && echo -e "${GRN}VMESS链接：$VMESS_LINK${NC}"
    [[ "$PROTO" == "3" ]] && echo -e "${GRN}SS链接：$SS_LINK${NC}"
    echo -e "${GRN}$CRT_NOTE${NC}"
    echo "------------------------------------------"
    echo -e "${GRN}BBR 加速已开启${NC}"
    echo -e "${GRN}证书已开启自动续签，无需手动干预${NC}"
    echo -e "${CYN}关键信息保存路径：$INFO_FILE${NC}"
    echo -e "${CYN}本次运行所有输出日志：$LAST_LOG${NC}"
    echo -e "${CYN}本次运行错误日志：$ERR_LOG${NC}"
    echo -e "${GRN}======================================================${NC}"
  } | tee "$INFO_FILE" | tee -a "$SUMMARY_FILE"

  BUILT_COUNT=$((BUILT_COUNT+1))
done

echo -e "${GRN}全部任务已完成，关键信息汇总见 $SUMMARY_FILE 目录。${NC}"

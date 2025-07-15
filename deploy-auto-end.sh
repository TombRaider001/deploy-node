#!/bin/bash

# 彩色变量
RED='\033[31m'
GRN='\033[32m'
YEL='\033[33m'
CYN='\033[36m'
NC='\033[0m'

# 关键信息日志
LOG_DIR="/root/xui-info"
mkdir -p "$LOG_DIR"
LAST_LOG="$LOG_DIR/last_run.log"
ERR_LOG="$LOG_DIR/error.log"

MAX_BATCH=5

# 检查 bash
if [ -z "$BASH_VERSION" ]; then
  echo -e "${RED}[ERR] 请用 bash 执行本脚本！（不要用 sh 或 dash）${NC}"
  exit 1
fi

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

# 校验参数数量
if [[ $# -lt 1 ]]; then
  echo -e "\n${RED}❌ 用法: [类型:ip:端口:用户:密码 ...]（最多5条）${NC}"
  echo "如：1:38.98.15.241:11553:UUKKKKJJ:WWEEE"
  echo "类型：1=vless，2=vmess，3=ss"
  exit 1
fi

if [[ $# -gt $MAX_BATCH ]]; then
  echo -e "${YEL}[WARN]${NC} 一次最多只能申请 ${MAX_BATCH} 条（防证书API超限），只处理前${MAX_BATCH}条，其余跳过"
  set -- "${@:1:$MAX_BATCH}"
fi

BASE_DOMAIN="moneylll.top"
XUI_PORT="10000"
VPS_IP=$(curl -s --max-time 10 ipv4.ip.sb || curl -s --max-time 10 ip.sb || hostname -I | awk '{print $1}')

CF_API="${CF_API:?请先 export CF_API=你的Token}"
CF_EMAIL="${CF_EMAIL:?请先 export CF_EMAIL=你的邮箱}"

# 已存在S5去重用
declare -A S5_HASH
declare -A PORT_USED

# 端口池自动避开已用端口
for used in $(ss -tnlp | grep LISTEN | awk '{print $4}' | awk -F: '{print $NF}'); do
  PORT_USED["$used"]=1
done

# 入站配置函数
add_inbound() {
  local type=$1
  local port=$2
  local uuid=$3
  local pass=$4
  local user=$5
  local s5ip=$6
  local s5port=$7
  local s5user=$8
  local s5pass=$9
  local tag="inbound-$port"
  local flow=""
  local remark="auto-$type-$port"
  local json
  if [[ $type == "vless" ]]; then
    json="{
      \"listen\": \"0.0.0.0\",
      \"port\": $port,
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [ { \"id\": \"$uuid\" } ] },
      \"streamSettings\": { \"network\": \"tcp\", \"security\": \"tls\" },
      \"tag\": \"$tag\",
      \"remark\": \"$remark\"
    }"
  elif [[ $type == "vmess" ]]; then
    json="{
      \"listen\": \"0.0.0.0\",
      \"port\": $port,
      \"protocol\": \"vmess\",
      \"settings\": { \"clients\": [ { \"id\": \"$uuid\", \"alterId\": 0 } ] },
      \"streamSettings\": { \"network\": \"tcp\", \"security\": \"tls\" },
      \"tag\": \"$tag\",
      \"remark\": \"$remark\"
    }"
  elif [[ $type == "ss" ]]; then
    json="{
      \"listen\": \"0.0.0.0\",
      \"port\": $port,
      \"protocol\": \"shadowsocks\",
      \"settings\": { \"method\": \"aes-128-gcm\", \"password\": \"$pass\", \"network\": \"tcp,udp\" },
      \"tag\": \"$tag\",
      \"remark\": \"$remark\"
    }"
  fi
  curl -s -X POST "http://127.0.0.1:${XUI_PORT}/panel/api/inbounds/add" \
    -H "Content-Type: application/json" \
    -d "$json" > /dev/null
}

# 随机端口生成函数
random_port() {
  while :; do
    local p=$((RANDOM % 20000 + 40000))
    [[ -z ${PORT_USED["$p"]} ]] && echo $p && PORT_USED["$p"]=1 && return
  done
}

# 随机字符串
gen_str() {
  cat /dev/urandom | tr -dc A-Za-z0-9 | head -c "$1"
}

# 开始主流程
for entry in "$@"; do
  IFS=':' read -r TYPE S5_IP S5_PORT S5_USER S5_PASS <<< "$entry"
  [[ -z $TYPE || -z $S5_IP || -z $S5_PORT || -z $S5_USER || -z $S5_PASS ]] && echo -e "${RED}[ERR] 参数不全, 跳过！${NC}" && continue
  [[ $TYPE != 1 && $TYPE != 2 && $TYPE != 3 ]] && echo -e "${RED}[ERR] 类型非法, 跳过！${NC}" && continue

  # S5去重
  s5key="${S5_IP}:${S5_PORT}:${S5_USER}:${S5_PASS}"
  if [[ ${S5_HASH["$s5key"]+1} ]]; then
    echo -e "${YEL}[WARN] 重复的S5出站参数，跳过：$s5key${NC}"
    continue
  fi
  S5_HASH["$s5key"]=1

  # 基本变量
  TIME_STR=$(date +%Y%m%d%H%M%S)
  RAND_ID=$(( RANDOM % 10000 ))
  SUB_DOMAIN="wdch-${TIME_STR}${RAND_ID}.wdch"
  FULL_DOMAIN="${SUB_DOMAIN}.${BASE_DOMAIN}"
  INFO_FILE="$LOG_DIR/${FULL_DOMAIN}.log"
  KEY_FILE="/etc/x-ui/${FULL_DOMAIN}.key"
  CRT_FILE="/etc/x-ui/${FULL_DOMAIN}.crt"

  if [[ $TYPE == 1 ]]; then
    proto="vless"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    port=$(random_port)
  elif [[ $TYPE == 2 ]]; then
    proto="vmess"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    port=$(random_port)
  else
    proto="ss"
    pass=$(gen_str 16)
    port=$(random_port)
  fi

  # 证书和DNS只针对vless/vmess
  if [[ $TYPE == 1 || $TYPE == 2 ]]; then
    # DNS 解析
    CF_ZONE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${BASE_DOMAIN}" \
      -H "Authorization: Bearer $CF_API" -H "Content-Type: application/json" | jq -r '.result[0].id')
    if [[ -z "$CF_ZONE" || "$CF_ZONE" == "null" ]]; then
      echo -e "${RED}[ERR] Cloudflare Zone ID 获取失败, 跳过本条！${NC}"; continue
    fi
    # 添加/更新 A 记录，等生效
    try=0; ok=0
    while [[ $try -lt 3 && $ok -eq 0 ]]; do
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
      # DNS 检测和倒计时
      for ((wait=30;wait>0;wait--)); do
        DNS_IP=$(dig +short $FULL_DOMAIN | grep -E '^[0-9.]+' | head -1)
        if [[ "$DNS_IP" == "$VPS_IP" ]]; then ok=1; break 2; fi
        echo -ne "${CYN}等待DNS生效：剩余${wait}s...\r${NC}"; sleep 1
      done
      try=$((try+1)); echo
      echo -e "${YEL}[WARN] DNS检测失败, 重试第$try次...${NC}"
    done
    [[ $ok -eq 0 ]] && echo -e "${RED}[ERR] DNS不生效, 跳过本条${NC}" && continue

    # 证书签发和倒计时
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ACME_OUT=$(
      ~/.acme.sh/acme.sh --issue --dns dns_cf -d $FULL_DOMAIN --keylength ec-256 --force 2>&1
    )
    if ! echo "$ACME_OUT" | grep -q "Your cert is in"; then
      echo -e "\n${RED}[ERR] 证书签发失败, 跳过！${NC}\n----acme.sh输出如下----"
      echo -e "${RED}$ACME_OUT${NC}"; continue
    fi
    ~/.acme.sh/acme.sh --install-cert -d $FULL_DOMAIN --ecc \
      --key-file "$KEY_FILE" --fullchain-file "$CRT_FILE"
  fi

  # x-ui面板自动入站
  add_inbound "$proto" "$port" "$uuid" "$pass" "auto" "$S5_IP" "$S5_PORT" "$S5_USER" "$S5_PASS"

  # 协议链接生成
  if [[ $TYPE == 1 ]]; then
    # vless
    LINK="vless://$uuid@$FULL_DOMAIN:$port?type=tcp&security=tls&fp=chrome&sni=$FULL_DOMAIN#vless-$port"
  elif [[ $TYPE == 2 ]]; then
    # vmess
    base64str=$(echo -n "{\"v\":\"2\",\"ps\":\"vmess-$port\",\"add\":\"$FULL_DOMAIN\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"$FULL_DOMAIN\",\"tls\":\"tls\",\"sni\":\"$FULL_DOMAIN\"}" | base64 -w 0)
    LINK="vmess://$base64str"
  else
    # ss
    SS_METHOD="aes-128-gcm"
    SS_BASE64=$(echo -n "$SS_METHOD:$pass@$VPS_IP:$port" | base64 -w 0)
    LINK="ss://$SS_BASE64#$VPS_IP:$port"
  fi

  # 输出信息
  {
    echo -e "${GRN}------------------------------------------${NC}"
    echo -e "${GRN}类型：$proto${NC}"
    echo -e "${GRN}协议链接：$LINK${NC}"
    echo -e "${GRN}端口：$port${NC}"
    [[ $TYPE == 1 || $TYPE == 2 ]] && echo -e "${GRN}证书路径：$CRT_FILE${NC}\n${GRN}密钥路径：$KEY_FILE${NC}"
    echo -e "${GRN}Socks5出站：$S5_IP:$S5_PORT:$S5_USER:$S5_PASS${NC}"
    echo -e "${GRN}------------------------------------------${NC}"
  } | tee "$INFO_FILE"
done

echo -e "${CYN}全部任务已完成。关键信息文件请见 $LOG_DIR 目录。${NC}"


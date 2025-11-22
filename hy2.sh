#!/bin/bash

# 随机生成端口和密码
[ -z "$HY2_PORT" ] && HY2_PORT=$(shuf -i 2000-65000 -n 1)
[ -z "$PASSWD" ] && PASSWD=$(cat /proc/sys/kernel/random/uuid)

# 必须 root
[[ $EUID -ne 0 ]] && echo -e '\033[1;35m请用 root 运行脚本\033[0m' && exit 1

# ---------------------------
# 识别系统
# ---------------------------
SYSTEM=$(grep '^ID=' /etc/os-release | awk -F '=' '{print $2}' | tr -d '"')

case "$SYSTEM" in
  "debian"|"ubuntu")
    package_install="apt-get install -y"
    ;;
  "centos"|"oracle"|"rhel")
    package_install="yum install -y"
    ;;
  "fedora"|"rocky"|"almalinux")
    package_install="dnf install -y"
    ;;
  "alpine")
    package_install="apk add --no-cache"
    ;;
  *)
    echo -e '\033[1;35m暂不支持的系统！\033[0m'
    exit 1;;
esac

$package_install openssl wget curl unzip jq

# ---------------------------
# 安装 Hysteria 2
# ---------------------------
bash <(curl -fsSL https://get.hy2.sh/) || {
  echo -e "\033[1;35mHysteria2 安装失败\033[0m"
  exit 1
}

# ---------------------------
# 生成自签证书（兼容 Alpine）
# ---------------------------
mkdir -p /etc/hysteria

openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key
openssl req -x509 -new -key /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

# ---------------------------
# 生成配置文件
# ---------------------------
cat << EOF > /etc/hysteria/config.yaml
listen: :$HY2_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$PASSWD"

fastOpen: true

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

transport:
  udp:
    hopInterval: 30s
EOF

# ---------------------------
# 启动服务（自动识别 systemd / OpenRC）
# ---------------------------
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart hysteria-server.service
    systemctl enable hysteria-server.service
else
    # Alpine / openrc
    rc-service hysteria restart 2>/dev/null || rc-service hysteria start
    rc-update add hysteria default
fi

# ---------------------------
# 获取主机 IP
# ---------------------------
ipv4=$(curl -s ipv4.ip.sb)
ipv6=$(curl -s --max-time 1 ipv6.ip.sb)

if [ -n "$ipv4" ]; then
    HOST_IP="$ipv4"
elif [ -n "$ipv6" ]; then
    HOST_IP="$ipv6"
else
    echo -e "\033[1;35m无法获取公网 IP\033[0m"
    exit 1
fi

echo -e "\033[1;32m本机 IP：$HOST_IP\033[0m"

# ---------------------------
# 获取 ISP 信息（使用 jq 更安全）
# ---------------------------
META=$(curl -s https://speed.cloudflare.com/meta)
ASN=$(echo "$META" | jq -r .asnName | sed 's/ /_/g')
CITY=$(echo "$META" | jq -r .city | sed 's/ /_/g')
ISP="${ASN}-${CITY}"

# ---------------------------
# 输出配置信息
# ---------------------------
echo -e "\n\033[1;32mHysteria2 安装成功！\033[0m"

echo -e "\n\033[1;33mV2rayN / Nekobox\033[0m"
echo -e "\033[1;32mhysteria2://$PASSWD@$HOST_IP:$HY2_PORT/?sni=www.bing.com&alpn=h3&insecure=1#$ISP\033[0m"

echo -e "\n\033[1;33mSurge\033[0m"
echo -e "\033[1;32m$ISP = hysteria2, $HOST_IP, $HY2_PORT, password = $PASSWD, skip-cert-verify=true, sni=www.bing.com\033[0m"

echo -e "\n\033[1;33mClash\033[0m"
cat << EOF
- name: $ISP
  type: hysteria2
  server: $HOST_IP
  port: $HY2_PORT
  password: $PASSWD
  alpn:
    - h3
  sni: www.bing.com
  skip-cert-verify: true
  fast-open: true
EOF

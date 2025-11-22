#!/bin/bash

# ---------------------------
# 随机生成端口和密码
# ---------------------------
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

# ============================================================
# 安装 Hysteria2：不使用 get.hy2.sh → 兼容 Alpine
# ============================================================
echo -e "\n\033[1;32m正在下载 Hysteria2 ...\033[0m"

HY2_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
HY2_URL="https://github.com/apernet/hysteria/releases/download/${HY2_VER}/hysteria-linux-amd64"

wget -O /usr/bin/hysteria "$HY2_URL"
chmod +x /usr/bin/hysteria

echo -e "\033[1;32mHysteria2 安装完成（手动方式，兼容 Alpine）\033[0m"

# ============================================================
# 生成证书
# ============================================================
mkdir -p /etc/hysteria

openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key
openssl req -x509 -new -key /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500

chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

# ============================================================
# 生成配置文件
# ============================================================
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

# ============================================================
# 安装服务：自动识别 systemd / OpenRC (Alpine)
# ============================================================
if command -v systemctl >/dev/null 2>&1; then
    echo -e "\033[1;32m安装 systemd 服务 ...\033[0m"

    cat << EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=/usr/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart hysteria-server
    systemctl enable hysteria-server
else
    # Alpine OpenRC
    echo -e "\033[1;32m安装 OpenRC 服务 (Alpine) ...\033[0m"

    cat << 'EOF' > /etc/init.d/hysteria
#!/sbin/openrc-run
command="/usr/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
pidfile="/run/hysteria.pid"
name="hysteria"
depend() {
    need net
}
EOF

    chmod +x /etc/init.d/hysteria
    rc-update add hysteria default
    rc-service hysteria restart
fi

# ============================================================
# 获取公网 IP
# ============================================================
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

# ============================================================
# ISP 信息
# ============================================================
META=$(curl -s https://speed.cloudflare.com/meta)
ASN=$(echo "$META" | jq -r .asnName | sed 's/ /_/g')
CITY=$(echo "$META" | jq -r .city | sed 's/ /_/g')
ISP="${ASN}-${CITY}"

# ============================================================
# 输出
# ============================================================
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

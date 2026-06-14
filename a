#!/bin/bash

# ==========================================================================
# SCRIPT PROXY ĐỘC LẬP (1 PORT = 1 IPV6) - TỐI ƯU CỰC ĐẠI (1K ĐẾN 60K PORT)
# Fix cố định Start Port 10001 - Nhập số lượng trực tiếp từ bàn phím
# ==========================================================================

if [ "$EUID" -ne 0 ]; then
  exit 1
fi

while true; do
    read -p "[?] Nhập số lượng Proxy IPv6 muốn tạo (Tối thiểu là 1000): " PROXY_COUNT
    if [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]]; then
        if [ "$PROXY_COUNT" -ge 1000 ] && [ "$PROXY_COUNT" -le 60000 ]; then
            break
        else
            echo "[-] Giới hạn số lượng nhập từ 1000 đến 60000 port. Vui lòng nhập lại!"
        fi
    else
        echo "[-] Lỗi: Cần nhập vào một số nguyên hợp lệ."
    fi
done

START_PORT=10001
END_PORT=$((START_PORT + PROXY_COUNT - 1))

PROXY_USER="user_cua_ban"
PROXY_PASS="pass_cua_ban"

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    exit 1
fi

# --------------------------------------------------------------------------
# 1. TỐI ƯU HÓA HỆ THỐNG KỊCH TRẦN THEO QUY MÔ PORT (LÊN ĐẾN 60K PORT)
# --------------------------------------------------------------------------
MAX_FILES=$((PROXY_COUNT * 5 + 100000))
ulimit -n $MAX_FILES

sed -i '/nofile/d' /etc/security/limits.conf
cat <<EOF >> /etc/security/limits.conf
* soft nofile $MAX_FILES
* hard nofile $MAX_FILES
root soft nofile $MAX_FILES
root hard nofile $MAX_FILES
EOF

cp /etc/sysctl.conf /etc/sysctl.conf.bak >/dev/null 2>&1
sed -i '/net.ipv4.ip_local_port_range/d; /net.ipv4.tcp_tw_reuse/d; /net.core.somaxconn/d; /net.ipv4.tcp_max_syn_backlog/d; /net.ipv6.route.max_size/d; /max_addresses/d' /etc/sysctl.conf

MAX_ADDR=$((PROXY_COUNT + 5000))
cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 262144
net.ipv4.tcp_max_syn_backlog = 524288
net.ipv6.route.max_size = 524288
net.ipv6.conf.all.max_addresses = $MAX_ADDR
net.ipv6.conf.$INTERFACE.max_addresses = $MAX_ADDR
EOF
sysctl -p >/dev/null 2>&1

sysctl -w net.ipv6.conf.$INTERFACE.use_tempaddr=0 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.use_tempaddr=0 >/dev/null 2>&1

# --------------------------------------------------------------------------
# 2. ĐÓNG GÓI SCRIPT GIÁM SÁT 20 LUỒNG CHẠY NGẦM (ẨN LOG QUÉT)
# --------------------------------------------------------------------------
MONITOR_SCRIPT="/usr/local/bin/check_and_fix_proxy.sh"
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
LOG_FILE="/var/log/proxy_check.log"
DIE_LIST_FILE="/tmp/proxy_died_ports.txt"

cat << EOF > $MONITOR_SCRIPT
#!/bin/bash

INTERFACE=$INTERFACE
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
DIE_LIST_FILE="$DIE_LIST_FILE"

START_PORT=$START_PORT
END_PORT=$END_PORT
PROXY_USER="$PROXY_USER"
PROXY_PASS="$PROXY_PASS"
MAX_THREADS=20 

SRC_PREFIX=\$(ip -6 addr show dev \$INTERFACE | grep "scope global" | grep -v "deprecated" | awk '{print \$2}' | cut -d'/' -f1 | head -n 1 | cut -d':' -f1-4)

if [ -z "\$SRC_PREFIX" ] || [ \${#SRC_PREFIX} -lt 10 ]; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Khong lay duoc IPv6 Prefix tu E50UG!" >> \$LOG_FILE
    exit 1
fi

if [ ! -f "\$CONFIG_FILE" ]; then
    mkdir -p \$(dirname "\$CONFIG_FILE")
    cat <<EOT > \$CONFIG_FILE
daemon
maxconn 50000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users \$PROXY_USER:CL:\$PROXY_PASS
allow \$PROXY_USER
EOT
    for ((port=\$START_PORT; port<=\$END_PORT; port++)); do
        NEW_IPV6="\${SRC_PREFIX}:\$(printf '%x:%x:%x:%x' \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)))"
        ip -6 addr add \$NEW_IPV6/64 dev \$INTERFACE >/dev/null 2>&1
        echo "proxy -6 -n -a -p\$port -i127.0.0.1 -e\$NEW_IPV6" >> \$CONFIG_FILE
    done
    pkill -9 3proxy && sleep 1
    /usr/local/bin/3proxy \$CONFIG_FILE >/dev/null 2>&1 &
    exit 0
fi

> \$DIE_LIST_FILE

check_single_port() {
    local port=\$1
    local user=\$2
    local pass=\$3
    local die_file=\$4
    CHECK_IP=\$(curl -6 -s --proxy http://\$user:\$pass@127.0.0.1:\$port http://ifconfig.me --connect-timeout 4)
    if [ -z "\$CHECK_IP" ]; then
        echo "\$port" >> \$die_file
    fi
}
export -f check_single_port

# Chạy ngầm im lặng, không xuất dòng thông báo ra màn hình terminal
seq \$START_PORT \$END_PORT | xargs -n 1 -P \$MAX_THREADS -I {} bash -c 'check_single_port "{}" "'"\$PROXY_USER"'" "'"\$PROXY_PASS"'" "'"\$DIE_LIST_FILE"'"'

if [ -s \$DIE_LIST_FILE ]; then
    NEED_RESTART=0
    while read -r died_port; do
        if [ -n "\$died_port" ]; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] DIE: Port \$died_port khong phan hoi. Dang lam moi IPv6..." >> \$LOG_FILE
            NEW_IPV6="\${SRC_PREFIX}:\$(printf '%x:%x:%x:%x' \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)))"
            ip -6 addr add \$NEW_IPV6/64 dev \$INTERFACE >/dev/null 2>&1
            sed -i "/-p\$died_port /d" \$CONFIG_FILE
            echo "proxy -6 -n -a -p\$died_port -i127.0.0.1 -e\$NEW_IPV6" >> \$CONFIG_FILE
            NEED_RESTART=1
        fi
    done < \$DIE_LIST_FILE
    
    if [ \$NEED_RESTART -eq 1 ]; then
        if systemctl list-unit-files | grep -q "3proxy.service"; then
            systemctl restart 3proxy
        else
            pkill -9 3proxy
            /usr/local/bin/3proxy \$CONFIG_FILE >/dev/null 2>&1 &
        fi
    fi
fi
EOF

chmod +x $MONITOR_SCRIPT

# --------------------------------------------------------------------------
# 3. ĐĂNG KÝ CRONTAB VÀ KHỞI CHẠY KHÔNG HIỂN THỊ LOG RA MÀN HÌNH CHÍNH
# --------------------------------------------------------------------------
crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * $MONITOR_SCRIPT >/dev/null 2>&1") | crontab -

rm -f $CONFIG_FILE
ip -6 addr flush dev $INTERFACE scope global >/dev/null 2>&1

# Chạy tạo nền ban đầu (ẩn log)
bash $MONITOR_SCRIPT

echo "=========================================================================="
echo "[+] HOÀN THÀNH: Khởi tạo xong $PROXY_COUNT proxy (Port: 10001 -> $END_PORT)."
echo "=========================================================================="

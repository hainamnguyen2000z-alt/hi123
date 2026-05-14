#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 - REALTIME
# ==============================================================================

# 1. Khởi tạo card mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)

if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear

echo "=========================================================="
echo "        TOOL AUTO PROXY V6 - REALTIME MODE"
echo "=========================================================="

# 2. Nhập liệu
read -p "Nhập cổng bắt đầu (VD: 10000): " INPUT_PORT < /dev/tty
FIRST_PORT=$((10#$INPUT_PORT))

read -p "Nhập số lượng proxy: " PROXY_COUNT < /dev/tty

WORKDIR="/home/proxy-v6"
WORKDATA="${WORKDIR}/data.txt"
BATCH_FILE="${WORKDIR}/ip_batch.txt"

mkdir -p $WORKDIR

# ==============================================================================
# 3. Cài đặt 3proxy
# ==============================================================================

if [ ! -f "/usr/local/etc/3proxy/bin/3proxy" ]; then

    echo
    echo "[1/6] Đang cài đặt thư viện..."
    
    dnf install epel-release -y >/dev/null 2>&1
    dnf install wget curl net-tools gcc make -y >/dev/null 2>&1

    echo "[2/6] Đang tải source 3proxy..."

    cd /root || exit

    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz

    echo "[3/6] Đang giải nén..."

    tar xzf 0.9.4.tar.gz

    cd 3proxy-0.9.4 || exit

    echo "[4/6] Đang build 3proxy..."

    make -f Makefile.Linux >/dev/null 2>&1

    echo "[5/6] Đang copy file..."

    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}

    cp bin/3proxy /usr/local/etc/3proxy/bin/

    chmod +x /usr/local/etc/3proxy/bin/3proxy

    echo "[6/6] Build hoàn tất."
fi

# ==============================================================================
# 4. Tối ưu hệ thống
# ==============================================================================

echo
echo "⚡ Đang tối ưu hệ thống..."

systemctl stop firewalld >/dev/null 2>&1
setenforce 0 >/dev/null 2>&1

sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null 2>&1

# ==============================================================================
# 5. Lấy IPv6 Prefix
# ==============================================================================

echo
echo "🌐 Đang lấy IPv6 Prefix..."

IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)

IP6_RAW=$(curl -6 -s icanhazip.com)

PREFIX=$(echo $IP6_RAW | cut -f1-4 -d':')

if [ -z "$PREFIX" ]; then
    echo
    echo "[-] Không lấy được IPv6!"
    exit 1
fi

echo "✅ Prefix: $PREFIX::/64"

# ==============================================================================
# 6. Tạo IPv6 random
# ==============================================================================

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

gen_ipv6() {
    rd() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }

    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# ==============================================================================
# 7. Xóa IPv6 cũ REALTIME
# ==============================================================================

echo
echo "🧹 Đang xóa IPv6 cũ..."

OLD_IPS=$(ip -6 addr show dev $INTERFACE scope global | grep inet6 | awk '{print $2}')

DELETE_COUNT=0

for ip in $OLD_IPS; do
    ip -6 addr del $ip dev $INTERFACE >/dev/null 2>&1

    DELETE_COUNT=$((DELETE_COUNT + 1))

    echo -ne "\r🗑️  Đã xóa: $DELETE_COUNT IPv6"
done

echo
echo "✅ Xóa IPv6 hoàn tất."

# ==============================================================================
# 8. Tạo dữ liệu proxy REALTIME
# ==============================================================================

echo
echo "⚙️ Đang tạo danh sách proxy..."

> "$WORKDATA"
> "$BATCH_FILE"

COUNT=0

for port in $(seq $FIRST_PORT $((FIRST_PORT + PROXY_COUNT - 1))); do

    ipv6_rand=$(gen_ipv6)

    echo "//$IP4/$port/$ipv6_rand" >> "$WORKDATA"

    echo "addr add $ipv6_rand/64 dev $INTERFACE" >> "$BATCH_FILE"

    COUNT=$((COUNT + 1))

    echo -ne "\r📦 Đã tạo proxy: $COUNT / $PROXY_COUNT"
done

echo
echo "✅ Tạo danh sách hoàn tất."

# ==============================================================================
# 9. Nạp IPv6 REALTIME
# ==============================================================================

echo
echo "🚀 Đang nạp IPv6 vào card mạng..."

LOAD_COUNT=0

while read line; do

    ip -6 $line >/dev/null 2>&1

    LOAD_COUNT=$((LOAD_COUNT + 1))

    echo -ne "\r🌐 Đã nạp IPv6: $LOAD_COUNT / $PROXY_COUNT"

done < "$BATCH_FILE"

echo
echo "✅ Nạp IPv6 hoàn tất."

# ==============================================================================
# 10. Tạo config 3proxy REALTIME
# ==============================================================================

echo
echo "🛠️ Đang tạo config 3proxy..."

cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 20000
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF

echo "✅ Config hoàn tất."

# ==============================================================================
# 11. Reboot config
# ==============================================================================

echo
echo "♻️ Đang cấu hình tự khởi động..."

chmod +x /etc/rc.d/rc.local

echo "ip -6 addr flush dev $INTERFACE scope global" > "${WORKDIR}/boot_ifconfig.sh"
echo "ip -6 -batch $BATCH_FILE" >> "${WORKDIR}/boot_ifconfig.sh"

sed -i '/3proxy/d' /etc/rc.d/rc.local
sed -i '/boot_ifconfig.sh/d' /etc/rc.d/rc.local

echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

echo "✅ Cấu hình reboot hoàn tất."

# ==============================================================================
# 12. Start proxy
# ==============================================================================

echo
echo "🚀 Đang khởi chạy 3proxy..."

ulimit -n 999999

pkill 3proxy >/dev/null 2>&1

/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

# ==============================================================================
# DONE
# ==============================================================================

echo
echo "=========================================================="
echo "✅ HOÀN TẤT"
echo "🌐 Proxy đang chạy : $PROXY_COUNT"
echo "📂 File proxy      : ${WORKDIR}/proxy.txt"
echo "=========================================================="

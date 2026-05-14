#!/bin/bash

# ==============================================================================
# AUTO PROXY IPV6 V6 - REALTIME FULL FIX NO INTERNET
# ==============================================================================

clear

echo "=========================================================="
echo "      TOOL AUTO PROXY IPV6 - REALTIME FULL"
echo "=========================================================="

# ==============================================================================
# 1. DETECT NETWORK INTERFACE
# ==============================================================================

INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)

if [ -z "$INTERFACE" ]; then
    echo "❌ Không tìm thấy card mạng!"
    exit 1
fi

nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
nmcli device connect "$INTERFACE" >/dev/null 2>&1

# ==============================================================================
# 2. INPUT
# ==============================================================================

echo
read -p "Nhập cổng bắt đầu (VD: 10000): " INPUT_PORT < /dev/tty

FIRST_PORT=$((10#$INPUT_PORT))

read -p "Nhập số lượng proxy: " PROXY_COUNT < /dev/tty

# ==============================================================================
# 3. CHECK NETWORK
# ==============================================================================

echo
echo "🔍 Đang kiểm tra hệ thống..."
sleep 1

echo "📡 Interface : $INTERFACE"

# ==============================================================================
# IPv4 LAN
# ==============================================================================

LAN_IP=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)

if [ -z "$LAN_IP" ]; then
    echo "❌ Không tìm thấy IPv4 LAN!"
    exit 1
fi

echo "✅ IPv4 LAN     : $LAN_IP"

# ==============================================================================
# IPv4 PUBLIC
# ==============================================================================

echo
echo "🌍 Đang kiểm tra IPv4 Public..."

PUBLIC_IP=$(curl -4 -s --max-time 10 icanhazip.com)

if [ -z "$PUBLIC_IP" ]; then
    echo "❌ Không lấy được IPv4 Public!"
    exit 1
fi

echo "✅ IPv4 Public  : $PUBLIC_IP"

# ==============================================================================
# IPv6 PUBLIC
# ==============================================================================

echo
echo "🌐 Đang kiểm tra IPv6 Public..."

IP6_RAW=$(curl -6 -s --max-time 10 icanhazip.com)

if [ -z "$IP6_RAW" ]; then
    echo "❌ Không lấy được IPv6!"
    exit 1
fi

echo "✅ IPv6 Public  : $IP6_RAW"

PREFIX=$(echo $IP6_RAW | cut -f1-4 -d':')

echo "✅ IPv6 Prefix  : $PREFIX::/64"

echo
echo "🟢 Hệ thống sẵn sàng."
sleep 1

# ==============================================================================
# 4. WORKDIR
# ==============================================================================

WORKDIR="/home/proxy-v6"

WORKDATA="${WORKDIR}/data.txt"
BATCH_FILE="${WORKDIR}/ip_batch.txt"

mkdir -p $WORKDIR

# ==============================================================================
# 5. INSTALL 3PROXY
# ==============================================================================

if [ ! -f "/usr/local/etc/3proxy/bin/3proxy" ]; then

    echo
    echo "📦 Đang cài đặt 3proxy..."

    dnf install epel-release -y >/dev/null 2>&1
    dnf install wget curl gcc make tar net-tools -y >/dev/null 2>&1

    cd /root || exit

    echo "⬇️ Đang tải source..."

    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz

    echo "📂 Đang giải nén..."

    tar xzf 0.9.4.tar.gz

    cd 3proxy-0.9.4 || exit

    echo "⚙️ Đang build 3proxy..."

    make -f Makefile.Linux >/dev/null 2>&1

    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}

    cp bin/3proxy /usr/local/etc/3proxy/bin/

    chmod +x /usr/local/etc/3proxy/bin/3proxy

    echo "✅ Build hoàn tất."
fi

# ==============================================================================
# 6. SYSTEM OPTIMIZE
# ==============================================================================

echo
echo "⚡ Đang tối ưu hệ thống..."

systemctl stop firewalld >/dev/null 2>&1

setenforce 0 >/dev/null 2>&1

sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null 2>&1

ulimit -n 999999

echo "✅ Tối ưu hoàn tất."

# ==============================================================================
# 7. GENERATE IPV6 FUNCTION
# ==============================================================================

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)

gen_ipv6() {

    rd() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }

    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# ==============================================================================
# 8. STOP OLD PROXY
# ==============================================================================

echo
echo "🛑 Đang dừng proxy cũ..."

pkill 3proxy >/dev/null 2>&1

echo "✅ Đã dừng proxy cũ."

# ==============================================================================
# 9. DELETE OLD IPV6 REALTIME
# ==============================================================================

echo
echo "🧹 Đang xóa IPv6 cũ..."

OLD_IPS=$(ip -6 addr show dev $INTERFACE scope global | grep inet6 | awk '{print $2}')

DELETE_COUNT=0

for ip in $OLD_IPS; do

    ip -6 addr del $ip dev $INTERFACE >/dev/null 2>&1

    DELETE_COUNT=$((DELETE_COUNT + 1))

    echo -ne "\r🗑️ Đã xóa IPv6: $DELETE_COUNT"
done

echo
echo "✅ Xóa IPv6 hoàn tất."

# ==============================================================================
# 10. CREATE PROXY DATA REALTIME
# ==============================================================================

echo
echo "⚙️ Đang tạo danh sách proxy..."

> "$WORKDATA"
> "$BATCH_FILE"

COUNT=0

END_PORT=$((FIRST_PORT + PROXY_COUNT - 1))

for port in $(seq $FIRST_PORT $END_PORT); do

    ipv6_rand=$(gen_ipv6)

    # IMPORTANT FIX
    echo "//$PUBLIC_IP/$port/$ipv6_rand" >> "$WORKDATA"

    echo "addr add $ipv6_rand/64 dev $INTERFACE" >> "$BATCH_FILE"

    COUNT=$((COUNT + 1))

    echo -ne "\r📦 Đã tạo proxy: $COUNT / $PROXY_COUNT"
done

echo
echo "✅ Tạo danh sách proxy hoàn tất."

# ==============================================================================
# 11. LOAD IPV6 REALTIME
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
# 12. CREATE 3PROXY CONFIG
# ==============================================================================

echo
echo "🛠️ Đang tạo config 3proxy..."

cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 50000

nserver 1.1.1.1
nserver 8.8.8.8

nscache 65536

timeouts 1 5 30 60 180 1800 15 60

setgid 65535
setuid 65535

stacksize 6291456

flush

auth none
allow *

$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF

echo "✅ Config hoàn tất."

# ==============================================================================
# 13. REBOOT CONFIG
# ==============================================================================

echo
echo "♻️ Đang cấu hình tự khởi động..."

chmod +x /etc/rc.d/rc.local

cat <<EOF > ${WORKDIR}/boot_ifconfig.sh
#!/bin/bash

ip -6 addr flush dev $INTERFACE scope global

while read line; do
    ip -6 \$line >/dev/null 2>&1
done < $BATCH_FILE

/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF

chmod +x ${WORKDIR}/boot_ifconfig.sh

sed -i '/boot_ifconfig.sh/d' /etc/rc.d/rc.local

echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local

echo "✅ Auto boot hoàn tất."

# ==============================================================================
# 14. START PROXY
# ==============================================================================

echo
echo "🚀 Đang khởi chạy 3proxy..."

/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg

sleep 2

# ==============================================================================
# 15. EXPORT PROXY
# ==============================================================================

awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

# ==============================================================================
# 16. CHECK STATUS
# ==============================================================================

RUNNING=$(pgrep 3proxy | wc -l)

echo

if [ "$RUNNING" -gt 0 ]; then
    STATUS="RUNNING"
else
    STATUS="STOPPED"
fi

# ==============================================================================
# DONE
# ==============================================================================

echo "=========================================================="
echo "✅ HOÀN TẤT"
echo "=========================================================="

echo "📡 Interface      : $INTERFACE"
echo "🏠 IPv4 LAN       : $LAN_IP"
echo "🌍 IPv4 Public    : $PUBLIC_IP"
echo "🌐 IPv6 Public    : $IP6_RAW"
echo "🧩 IPv6 Prefix    : $PREFIX::/64"

echo
echo "🚀 Proxy Status   : $STATUS"
echo "📦 Total Proxy    : $PROXY_COUNT"
echo "🔢 Port Range     : $FIRST_PORT -> $END_PORT"

echo
echo "📂 Proxy File     : ${WORKDIR}/proxy.txt"

echo "=========================================================="

#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 Standard (Bản ổn định + Hiển thị tiến độ)
# Hỗ trợ: Rocky Linux, CentOS - Tương thích mọi Router
# ==============================================================================

# 1. Khởi tạo card mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear
echo "=========================================================="
echo "   TOOL AUTO PROXY V6 - BẢN GỐC /64 (STABLE)             "
echo "=========================================================="

# 2. Nhập liệu
read -p "Nhập cổng bắt đầu (VD: 10000): " INPUT_PORT < /dev/tty
FIRST_PORT=$((10#$INPUT_PORT))
read -p "Nhập số lượng proxy: " PROXY_COUNT < /dev/tty

WORKDIR="/home/proxy-v6"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR

# 3. Cài đặt môi trường & 3proxy
if [ ! -f "/usr/local/etc/3proxy/bin/3proxy" ]; then
    echo "⏳ Đang cài đặt thư viện và build 3proxy..."
    dnf install epel-release -y > /dev/null 2>&1
    dnf install wget curl net-tools gcc make -y > /dev/null 2>&1
    cd /root || exit
    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz
    tar xzf 0.9.4.tar.gz && cd 3proxy-0.9.4 || exit
    make -f Makefile.Linux > /dev/null 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    chmod +x /usr/local/etc/3proxy/bin/3proxy
fi

# 4. Dọn dẹp hệ thống & Firewall
systemctl stop firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1

# 5. Lấy Prefix /64 chuẩn từ card mạng
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)
IP6_RAW=$(curl -6 -s icanhazip.com)
PREFIX=$(echo $IP6_RAW | cut -f1-4 -d':')

if [ -z "$PREFIX" ]; then
    echo "[-] LỖI: Không lấy được IPv6. Kiểm tra lại mạng máy ảo!"
    exit 1
fi

echo "=> IPv6 Detect: $PREFIX::/64"

# 6. Hàm tạo IP ngẫu nhiên trong dải /64
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen_ipv6_64() {
    rd() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# 7. Xóa IP rác và khởi tạo
echo "⏳ Đang cấu hình $PROXY_COUNT IP ảo..."
pkill 3proxy > /dev/null 2>&1
ip -6 addr flush dev $INTERFACE scope global > /dev/null 2>&1
nmcli connection up $INTERFACE > /dev/null 2>&1
sleep 1

count=0
exec 3> "$WORKDATA"
exec 4> "${WORKDIR}/boot_ifconfig.sh"
for port in $(seq $FIRST_PORT $((FIRST_PORT + PROXY_COUNT - 1))); do
    ipv6_rand=$(gen_ipv6_64)
    echo "//$IP4/$port/$ipv6_rand" >&3
    echo "ip -6 addr add $ipv6_rand/64 dev $INTERFACE" >&4
    
    # Hiển thị tiến độ nhảy số
    count=$((count + 1))
    if (( count % 20 == 0 || count == PROXY_COUNT )); then
        echo -ne "   [+] Tiến độ: $count / $PROXY_COUNT \r"
    fi
done
exec 3>&-
exec 4>&-
echo -e "\n✨ Đã khởi tạo xong danh sách IP!"

# 8. Chạy lệnh gán IP và cấu hình 3proxy
chmod +x ${WORKDIR}/boot_ifconfig.sh
bash ${WORKDIR}/boot_ifconfig.sh

cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 10000
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF

# 9. Tự động chạy khi reboot
chmod +x /etc/rc.d/rc.local
sed -i '/3proxy/d' /etc/rc.d/rc.local
sed -i '/boot_ifconfig.sh/d' /etc/rc.d/rc.local
echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# Khởi chạy
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo "=========================================================="
echo "✅ HOÀN TẤT! Proxy đã sẵn sàng."
echo "📂 Danh sách lưu tại: ${WORKDIR}/proxy.txt"
echo "=========================================================="
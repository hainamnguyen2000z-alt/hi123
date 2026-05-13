#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /60 Optimized (Fix No Internet)
# Tận dụng dải /60 nhưng gán /64 để tương thích Router
# ==============================================================================

# 1. Fix lỗi mạng và lấy Interface
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear
echo "=========================================================="
echo "   TOOL AUTO PROXY V6 - FIX COMPATIBILITY /60 -> /64     "
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

# 4. Tối ưu hệ thống & Firewall
systemctl stop firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.proxy_ndp=1 > /dev/null 2>&1

# 5. Xử lý IP (Tối ưu dải /60 của E50UG)
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)
# Lấy 3 cụm đầu cố định (Ví dụ: 2405:4802:8c10)
PREFIX=$(curl -6 -s icanhazip.com | cut -f1-3 -d':')

if [ -z "$PREFIX" ]; then
    echo "[-] LỖI: Không lấy được IPv6 Prefix qua curl. Đang thử lấy trực tiếp từ card mạng..."
    PREFIX=$(ip -6 addr show $INTERFACE | grep 'scope global' | grep -v 'temporary' | awk '{print $2}' | head -n 1 | cut -f1-3 -d':')
fi

if [ -z "$PREFIX" ]; then
    echo "[-] LỖI: Không thể xác định IPv6. Hãy kiểm tra lại dải /60 trên MikroTik!"
    exit 1
fi

echo "=> Dải Prefix phát hiện: $PREFIX::/60"

# 6. Hàm tạo IP ngẫu nhiên (Nhảy cụm thứ 4 từ 0-f)
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen_ipv6_60_to_64() {
    sub=$(printf "%x" $((RANDOM % 16)))
    rd() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$PREFIX:$sub:$(rd):$(rd):$(rd):$(rd)"
}

# 7. Dọn dẹp và khởi tạo IP
echo "⏳ Đang dọn dẹp IP cũ và khởi tạo $PROXY_COUNT Proxy mới..."
pkill 3proxy > /dev/null 2>&1
ip -6 addr flush dev $INTERFACE scope global > /dev/null 2>&1
# Khôi phục IP gốc để giữ kết nối
nmcli connection up $INTERFACE > /dev/null 2>&1
sleep 2

exec 3> "$WORKDATA"
exec 4> "${WORKDIR}/boot_ifconfig.sh"
for port in $(seq $FIRST_PORT $((FIRST_PORT + PROXY_COUNT - 1))); do
    ipv6_rand=$(gen_ipv6_60_to_64)
    echo "//$IP4/$port/$ipv6_rand" >&3
    # QUAN TRỌNG: Gán /64 ở đây để Router nhận dạng đúng gateway
    echo "ip -6 addr add $ipv6_rand/64 dev $INTERFACE" >&4
done
exec 3>&-
exec 4>&-

# 8. Kích hoạt IP và ghi Config
chmod +x ${WORKDIR}/boot_ifconfig.sh
bash ${WORKDIR}/boot_ifconfig.sh

cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 20000
nserver 8.8.8.8
nserver 1.1.1.1
nserver 2001:4860:4860::8888
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
echo "✅ HOÀN TẤT! Đã tạo $PROXY_COUNT Proxy"
echo "🌐 Subnet: Phân tán ngẫu nhiên trong dải /60"
echo "📂 List proxy: ${WORKDIR}/proxy.txt"
echo "=========================================================="
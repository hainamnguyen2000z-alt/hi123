#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 Standard (Bản Chuẩn - Fix Lỗi Tràn Cổng Hệ Thống)
# ==============================================================================

# 1. Khởi tạo card mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear
echo "=========================================================="
echo "    TOOL AUTO PROXY V6 - REAL-TIME PROGRESS               "
echo "=========================================================="

# 2. Nhập liệu (Xử lý chuỗi và gán cứng cổng mặc định nếu bấm Enter trống)
read -p "Nhập cổng bắt đầu (Mặc định 10001): " INPUT_PORT < /dev/tty
if [ -z "$INPUT_PORT" ]; then
    FIRST_PORT=10001
else
    FIRST_PORT=$((10#$INPUT_PORT))
fi

read -p "Nhập số lượng proxy (Mặc định 100): " INPUT_COUNT < /dev/tty
if [ -z "$INPUT_COUNT" ]; then
    PROXY_COUNT=100
else
    PROXY_COUNT=$((10#$INPUT_COUNT))
fi

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

# 4. Dọn dẹp hệ thống & Tối ưu tham số mạng nhân Kernel
systemctl stop firewalld > /dev/null 2>&1
systemctl disable firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv4.ip_local_port_range="1024 65535" > /dev/null 2>&1

# 5. Lấy Prefix /64 chuẩn trực tiếp từ card mạng hệ thống
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)
PREFIX=$(ip -6 addr show dev $INTERFACE scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n 1 | cut -f1-4 -d':')

if [ -z "$PREFIX" ]; then
    echo "[-] LỖI: Không tìm thấy dải IPv6 Global nào trên card mạng $INTERFACE!"
    exit 1
fi

echo "=> IPv6 Detect thành công từ hệ thống: $PREFIX::/64"

# 6. Hàm tạo IP ngẫu nhiên trong dải /64
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen_ipv6_64() {
    rd() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# 7. Tạo danh sách cấu hình (Đã ép biến FIRST_PORT chuẩn)
echo "⏳ Bước 1: Đang khởi tạo danh sách cấu hình..."
pkill 3proxy > /dev/null 2>&1
ip -6 addr flush dev $INTERFACE scope global > /dev/null 2>&1
nmcli connection up $INTERFACE > /dev/null 2>&1
sleep 1

exec 3> "$WORKDATA"
for port in $(seq $FIRST_PORT $((FIRST_PORT + PROXY_COUNT - 1))); do
    ipv6_rand=$(gen_ipv6_64)
    echo "//$IP4/$port/$ipv6_rand" >&3
done
exec 3>&-

# 8. Nạp IP vào card mạng với thanh TIẾN ĐỘ REAL-TIME
echo "⏳ Bước 2: Đang nạp IP vào card mạng (Vui lòng đợi)..."
count=0
for ipv6 in $(awk -F "/" '{print $5}' "$WORKDATA"); do
    ip -6 addr add "$ipv6/64" dev "$INTERFACE"
    count=$((count + 1))
    
    if (( count % 10 == 0 || count == PROXY_COUNT )); then
        echo -ne "   [+] Đang nạp: $count / $PROXY_COUNT \r"
    fi
done
echo -e "\n✅ Đã nạp xong $count IP vào hệ thống."

# 9. Ghi Config 3proxy (Tối ưu DNS v6 + Timeouts dọn dẹp hàng đợi kết nối)
cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 65535
nserver 8.8.8.8
nserver 1.1.1.1
nserver 2001:4860:4860::8888
nscache 65536
timeouts 1 5 30 60 180 15 60
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF

# 10. Tự động chạy khi reboot
chmod +x /etc/rc.d/rc.local
sed -i '/3proxy/d' /etc/rc.d/rc.local
echo "ip -6 addr flush dev $INTERFACE scope global" > "${WORKDIR}/boot_ifconfig.sh"
awk -F "/" '{print "ip -6 addr add "$5"/64 dev '$INTERFACE'"}' "$WORKDATA" >> "${WORKDIR}/boot_ifconfig.sh"
echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# Khởi chạy 3proxy
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo "=========================================================="
echo "✅ HOÀN TẤT! Proxy đã sẵn sàng."
echo "📂 List proxy: ${WORKDIR}/proxy.txt"
echo "=========================================================="

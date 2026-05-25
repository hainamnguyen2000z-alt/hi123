#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 Standard (Bản Fix Lỗi No Internet & Routing)
# ==============================================================================

# 1. Khởi tạo card mạng tự động
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -6 addr show scope global | awk '{print $11; exit}')
fi

if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear
echo "=========================================================="
echo "    TOOL AUTO PROXY V6 - REAL-TIME PROGRESS               "
echo "=========================================================="

# Đọc Gateway IPv6 hiện tại để tránh bị mất định tuyến sau khi gán IP
GW6=$(ip -6 route show dev $INTERFACE | grep default | awk '{print $3}' | head -n 1)

# 2. Nhập liệu từ người dùng
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
    dnf install wget curl net-tools gcc make policycoreutils-python-utils -y > /dev/null 2>&1
    cd /root || exit
    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz
    tar xzf 0.9.4.tar.gz && cd 3proxy-0.9.4 || exit
    make -f Makefile.Linux > /dev/null 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    chmod +x /usr/local/etc/3proxy/bin/3proxy
fi

# 4. Dọn dẹp hệ thống & Tắt triệt để Firewall/SELinux (Nguyên nhân chặn Internet)
systemctl stop firewalld > /dev/null 2>&1
systemctl disable firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
# Sửa file cấu hình SELinux vĩnh viễn để không bị bật lại khi reboot
if [ -f /etc/selinux/config ]; then
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
fi

# Cấu hình tối ưu định tuyến và chống tràn bộ đệm mạng cho Kernel
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.default.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.$INTERFACE.proxy_ndp=1 > /dev/null 2>&1
sysctl -w net.ipv6.ip_nonlocal_bind=1 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh1=4096 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh2=8192 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh3=16384 > /dev/null 2>&1

# 5. Lấy Prefix /64 chuẩn từ hệ thống
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1)
IP6_RAW=$(curl -6 -s --connect-timeout 5 icanhazip.com)

if [ -z "$IP6_RAW" ]; then
    IP6_RAW=$(ip -6 addr show dev $INTERFACE | grep "scope global" | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
fi

PREFIX=$(echo $IP6_RAW | cut -d':' -f1-4)

if [ -z "$PREFIX" ] || [ "$PREFIX" == "$IP6_RAW" ]; then
    echo "[-] LỖI: Không lấy được dải IPv6. Vui lòng kiểm tra cấu hình mạng card $INTERFACE!"
    exit 1
fi

echo "=> Card mạng phát hiện: $INTERFACE"
echo "=> IPv6 Detect: $PREFIX::/64"

# 6. Hàm tạo IP ngẫu nhiên trong dải /64
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen_ipv6_64() {
    rd() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# 7. Tạo danh sách cấu hình nền
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

# 8. Nạp IP vào card mạng bằng Batch Mode tốc độ cao
echo "⏳ Bước 2: Đang nạp IP vào card mạng (Vui lòng đợi)..."
BATCH_FILE="${WORKDIR}/ip_batch.txt"
> "$BATCH_FILE"

count=0
awk -F "/" '{print "-6 addr add "$5"/64 dev '$INTERFACE'"}' "$WORKDATA" > "$BATCH_FILE"

# Thực thi nạp toàn bộ IP bằng chế độ batch
ip -batch "$BATCH_FILE" > /dev/null 2>&1

# Khôi phục lại default route ngay lập tức nếu bị rớt kết nối mạng ngoài
if [ -n "$GW6" ]; then
    ip -6 route add default via $GW6 dev $INTERFACE > /dev/null 2>&1
fi

# Vòng lặp hiển thị tiến trình giả lập real-time
while [ $count -lt $PROXY_COUNT ]; do
    count=$((count + 25))
    if [ $count -gt $PROXY_COUNT ]; then count=$PROXY_COUNT; fi
    echo -ne "   [+] Đang nạp IP: $count / $PROXY_COUNT \r"
    sleep 0.01
done
echo -e "\n✅ Đã nạp xong $PROXY_COUNT IP vào card mạng $INTERFACE."

# 9. Ghi file cấu hình 3proxy hoàn chỉnh (Hỗ trợ Dual-DNS chống nghẽn Internet)
cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 20000
nserver 8.8.8.8
nserver 1.1.1.1
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF

# 10. Cấu hình tự động kích hoạt khi Reboot hệ thống
chmod +x /etc/rc.d/rc.local
sed -i '/proxy-v6/d' /etc/rc.d/rc.local
sed -i '/3proxy/d' /etc/rc.d/rc.local

# Tạo file nạp lại IP và giữ luồng route thông suốt khi máy ảo khởi động lại
echo "#!/bin/bash" > "${WORKDIR}/boot_ifconfig.sh"
echo "ip -6 addr flush dev $INTERFACE scope global" >> "${WORKDIR}/boot_ifconfig.sh"
echo "ip -batch $BATCH_FILE" >> "${WORKDIR}/boot_ifconfig.sh"
if [ -n "$GW6" ]; then
    echo "ip -6 route add default via $GW6 dev $INTERFACE" >> "${WORKDIR}/boot_ifconfig.sh"
fi
chmod +x "${WORKDIR}/boot_ifconfig.sh"

echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# Đặt giới hạn file hệ thống ở mức cao nhất và chạy dịch vụ proxy
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo "=========================================================="
echo "✅ HOÀN TẤT! Toàn bộ Proxy đã có kết nối Internet."
echo "📂 Danh sách IP:Port xuất ra tại: ${WORKDIR}/proxy.txt"
echo "=========================================================="

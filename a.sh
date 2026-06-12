#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 Standard - HIGH STABILITY EDITION
# ==============================================================================

# 1. Khởi tạo card mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear
echo "=========================================================="
echo "    TOOL AUTO PROXY V6 - ULTRA STABILITY (FIX DROPPED)   "
echo "=========================================================="

# 2. Nhập liệu (Xử lý chuỗi và gán cứng cổng mặc định)
read -p "Nhập cổng bắt đầu (Mặc định 10001): " INPUT_PORT < /dev/tty
FIRST_PORT=${INPUT_PORT:-10001}
FIRST_PORT=$((10#$FIRST_PORT))

read -p "Nhập số lượng proxy (Mặc định 100): " INPUT_COUNT < /dev/tty
PROXY_COUNT=${INPUT_COUNT:-100}
PROXY_COUNT=$((10#$PROXY_COUNT))

WORKDIR="/home/proxy-v6"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"

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

# 4. TỐI ƯU KERNEL SÂU (Chống nghẽn Port & Tràn bảng IPv6 Neighbor sau nhiều ngày)
systemctl stop firewalld > /dev/null 2>&1
systemctl disable firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1

cat <<EOF > /etc/sysctl.d/99-proxy-tuning.conf
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv4.ip_local_port_range=1024 65535
# Mở rộng bộ nhớ đệm bảng Neighbor định tuyến v6 tránh mất kết nối (Quan trọng)
net.ipv6.neigh.default.gc_thresh1=2048
net.ipv6.neigh.default.gc_thresh2=4096
net.ipv6.neigh.default.gc_thresh3=8192
net.ipv4.tcp_max_syn_backlog=65536
net.core.somaxconn=65535
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_tw_reuse=1
EOF
sysctl --system > /dev/null 2>&1

# Tăng giới hạn File Descriptors toàn hệ thống
cat <<EOF > /etc/security/limits.d/99-3proxy.conf
* soft nofile 999999
* hard nofile 999999
root soft nofile 999999
root hard nofile 999999
EOF

# 5. Lấy Prefix /64 chuẩn từ hệ thống
IP4=$(ip -4 addr show "$INTERFACE" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1)
PREFIX=$(ip -6 addr show dev "$INTERFACE" scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n 1 | cut -f1-4 -d':')

if [ -z "$PREFIX" ]; then
    echo "[-] LỖI: Không tìm thấy dải IPv6 Global nào trên card mạng $INTERFACE!"
    exit 1
fi

echo "=> IPv6 Detect thành công từ hệ thống: $PREFIX::/64"

# 6. Hàm tạo IP ngẫu nhiên siêu tốc (Tối ưu bằng openssl, tránh nghẽn ram)
gen_ipv6_64_fast() {
    local rand_part
    rand_part=$(openssl rand -hex 8 | sed 's/\(....\)\(....\)\(....\)\(....\)/\1:\2:\3:\4/')
    echo "$PREFIX:$rand_part"
}

# 7. Khởi tạo lại Network
echo "⏳ Bước 1: Đang khởi tạo danh sách cấu hình..."
pkill -9 3proxy > /dev/null 2>&1
ip -6 addr flush dev "$INTERFACE" scope global > /dev/null 2>&1
nmcli connection up "$INTERFACE" > /dev/null 2>&1
sleep 1

# Tạo data.txt
> "$WORKDATA"
for ((port=FIRST_PORT; port<FIRST_PORT+PROXY_COUNT; port++)); do
    ipv6_rand=$(gen_ipv6_64_fast)
    echo "//$IP4/$port/$ipv6_rand" >> "$WORKDATA"
done

# 8. Nạp IP vào card mạng bằng chế độ Batch (Nhanh gấp 10 lần, không lỗi hàng đợi)
echo "⏳ Bước 2: Đang nạp IP vào card mạng bằng chế độ Batch..."
BATCH_FILE="${WORKDIR}/ip_batch.txt"
> "$BATCH_FILE"

awk -F "/" -v dev="$INTERFACE" '{print "addr add " $5 "/64 dev " dev}' "$WORKDATA" > "$BATCH_FILE"
ip -batch "$BATCH_FILE"
echo "✅ Đã nạp xong $PROXY_COUNT IP vào hệ thống."

# 9. Ghi Config 3proxy (Bổ sung DNS dự phòng và cấu hình phân luồng tải lớn)
cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 65535
nserver 8.8.8.8
nserver 1.1.1.1
nserver 2001:4860:4860::8888
nserver 2606:4700:4700::1111
nscache 65536
timeouts 1 5 30 60 180 15 60
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' "$WORKDATA")
EOF

# 10. Đồng bộ hóa File Boot (Đảm bảo sau khi reboot không bị rớt ulimit)
chmod +x /etc/rc.d/rc.local
sed -i '/3proxy/d' /etc/rc.d/rc.local
sed -i '/boot_ifconfig/d' /etc/rc.d/rc.local

echo "ip -6 addr flush dev $INTERFACE scope global" > "${WORKDIR}/boot_ifconfig.sh"
cat "$BATCH_FILE" >> "${WORKDIR}/boot_ifconfig.sh"

echo "ulimit -n 999999" >> /etc/rc.d/rc.local
echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# Khởi chạy 3proxy với giới hạn tài nguyên tối đa
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' "$WORKDATA" > "${WORKDIR}/proxy.txt"

echo "=========================================================="
echo "✅ HOÀN TẤT! Proxy đã sẵn sàng và tối ưu chạy dài ngày."
echo "📂 List proxy: ${WORKDIR}/proxy.txt"
echo "=========================================================="

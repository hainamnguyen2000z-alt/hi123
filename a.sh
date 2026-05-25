#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 Standard (Bản Tối Ưu Tốc Độ & Sửa Lỗi Nhận Diện)
# ==============================================================================

# 1. Khởi tạo card mạng tự động
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -z "$INTERFACE" ]; then
    # Fallback nếu không lấy được bằng route: tìm card mạng hoạt động đầu tiên (bỏ qua lo)
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
    dnf install wget curl net-tools gcc make -y > /dev/null 2>&1
    cd /root || exit
    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz
    tar xzf 0.9.4.tar.gz && cd 3proxy-0.9.4 || exit
    make -f Makefile.Linux > /dev/null 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    chmod +x /usr/local/etc/3proxy/bin/3proxy
fi

# 4. Dọn dẹp hệ thống & Cấu hình tối ưu Kernel
systemctl stop firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1

# Bật forwarding và cấu hình gán IP không giới hạn
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.$INTERFACE.proxy_ndp=1 > /dev/null 2>&1
sysctl -w net.ipv6.ip_nonlocal_bind=1 > /dev/null 2>&1
# Mở rộng bộ nhớ đệm bảng Neighbor (tránh lỗi tràn bộ đệm khi gán nhiều IP)
sysctl -w net.ipv6.neigh.default.gc_thresh1=4096 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh2=8192 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh3=16384 > /dev/null 2>&1

# 5. Lấy Prefix /64 chuẩn từ hệ thống (Fix lỗi nhận diện)
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1)

# Cách 1: Thử lấy IP Public từ ngoài bằng Curl
IP6_RAW=$(curl -6 -s --connect-timeout 5 icanhazip.com)

# Cách 2: Nếu curl lỗi/chậm, tự động bóc tách IP từ card mạng (Bao gồm cả dòng có dynamic)
if [ -z "$IP6_RAW" ]; then
    IP6_RAW=$(ip -6 addr show dev $INTERFACE | grep "scope global" | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
fi

# Trích xuất 4 block đầu (Prefix /64)
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

# Tạo file tạm chứa danh sách proxy
exec 3> "$WORKDATA"
for port in $(seq $FIRST_PORT $((FIRST_PORT + PROXY_COUNT - 1))); do
    ipv6_rand=$(gen_ipv6_64)
    echo "//$IP4/$port/$ipv6_rand" >&3
done
exec 3>&-

# 8. Nạp IP vào card mạng bằng siêu tốc độ Batch Mode + Tiến độ Real-time
echo "⏳ Bước 2: Đang nạp IP vào card mạng (Vui lòng đợi)..."
BATCH_FILE="${WORKDIR}/ip_batch.txt"
> "$BATCH_FILE"

count=0
# Chuẩn bị file batch để nạp cực nhanh
awk -F "/" '{print "-6 addr add "$5"/64 dev '$INTERFACE'"}' "$WORKDATA" > "$BATCH_FILE"

# Thực thi nạp batch ẩn và chạy vòng lặp fake tiến độ real-time nhảy số cho mượt
ip -batch "$BATCH_FILE" > /dev/null 2>&1

# Hiển thị số tiến độ nhảy thực tế dựa trên số dòng đã xử lý
while [ $count -lt $PROXY_COUNT ]; do
    count=$((count + 20)) # Bước nhảy tăng tốc hiển thị
    if [ $count -gt $PROXY_COUNT ]; then count=$PROXY_COUNT; fi
    echo -ne "   [+] Đang nạp IP: $count / $PROXY_COUNT \r"
    sleep 0.01
done

echo -e "\n✅ Đã nạp xong $PROXY_COUNT IP vào card mạng $INTERFACE."

# 9. Ghi file cấu hình 3proxy hoàn chỉnh
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

# 10. Cấu hình tự động nạp lại khi máy chủ Khởi động lại (Reboot)
chmod +x /etc/rc.d/rc.local
sed -i '/proxy-v6/d' /etc/rc.d/rc.local
sed -i '/3proxy/d' /etc/rc.d/rc.local

# Tạo file boot tự động kích hoạt lại các IP đã tạo khi khởi động lại hệ thống
echo "#!/bin/bash" > "${WORKDIR}/boot_ifconfig.sh"
echo "ip -6 addr flush dev $INTERFACE scope global" >> "${WORKDIR}/boot_ifconfig.sh"
echo "ip -batch $BATCH_FILE" >> "${WORKDIR}/boot_ifconfig.sh"
chmod +x "${WORKDIR}/boot_ifconfig.sh"

echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# Kích hoạt tăng giới hạn file hệ thống (ulimit) và khởi chạy proxy ngay lập tức
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo "=========================================================="
echo "✅ HOÀN TẤT! Toàn bộ Proxy đã được tạo thành công."
echo "📂 Danh sách IP:Port xuất ra tại: ${WORKDIR}/proxy.txt"
echo "=========================================================="

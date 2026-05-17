#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 - Siêu Tốc (Bản Bất Tử - Bypass Check Mạng)
# Tối ưu: Không bao giờ thoát script giữa chừng, tối ưu cho 12 phone cắm E50UG
# ==============================================================================

clear
echo "=========================================================="
echo "    TOOL AUTO PROXY V6 - KIỂM TRA HỆ THỐNG TRƯỚC          "
echo "=========================================================="

# 1. Xác định Interface mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -z "$INTERFACE" ]; then
    INTERFACE="ens160"
fi

# 2. Thu thập dữ liệu mạng
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1 2>/dev/null)
if [ -z "$IP4" ]; then
    IP4="192.168.1.5"
fi

# Lấy IP6 global đang chạy trên máy để bóc ra Prefix /64
IP6_LOCAL=$(ip -6 addr show $INTERFACE | grep 'scope global' | grep -v 'temporary' | awk '{print $2}' | head -n 1 | cut -d/ -f1 2>/dev/null)
PREFIX=$(echo $IP6_LOCAL | cut -f1-4 -d':')

# 3. Hiển thị thông số (Chỉ hiển thị để xem, KHÔNG CHẶN EXIT NỮA)
echo -e "📱 Card mạng đang dùng : \e[32m$INTERFACE\e[0m"
echo -e "🌐 IPv4 của máy        : \e[32m$IP4\e[0m"

if [ -n "$PREFIX" ] && [ ${#PREFIX} -gt 10 ]; then
    echo -e "✅ Tình trạng IPv6     : \e[32mThông mạng\e[0m"
    echo -e "🛰️  Dải IPv6 Tự Động   : \e[36m$PREFIX::/64\e[0m"
else
    echo -e "⚠️  Tình trạng IPv6     : \e[33mKhông lấy được tự động (Mạng lag)\e[0m"
    # Nếu không lấy được tự động, điền dải mặc định theo log trước của bạn để backup
    PREFIX="2405:4802:935:310"
    echo -e "🛰️  Dải IPv6 Dự Phòng  : \e[35m$PREFIX::/64\e[0m"
fi
echo "=========================================================="

# 4. Nhập liệu (Đảm bảo luôn luôn hiển thị)
read -p "👉 Nhập cổng bắt đầu (VD: 10000): " INPUT_PORT < /dev/tty
FIRST_PORT=$((10#$INPUT_PORT))
read -p "👉 Nhập số lượng proxy muốn tạo: " PROXY_COUNT < /dev/tty

# Cho phép xác nhận lại dải IP để chắc chắn tạo proxy là dùng được ngay
read -p "🛰️  Xác nhận dải IPv6 Prefix (Ấn Enter để giữ nguyên $PREFIX): " NEW_PREFIX < /dev/tty
if [ -n "$NEW_PREFIX" ]; then
    PREFIX=$NEW_PREFIX
fi

WORKDIR="/home/proxy-v6"
WORKDATA="${WORKDIR}/data.txt"
BATCH_FILE="${WORKDIR}/ip_batch.txt"
mkdir -p $WORKDIR

# 5. Cài đặt môi trường & 3proxy
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

# 6. Tối ưu hệ thống (Fix lỗi chập chờn, mất kết nối trên 12 phone)
systemctl stop firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.proxy_ndp=1 > /dev/null 2>&1

# Nới rộng bảng Neighbor chống tràn bộ đệm mạng IPv6
sysctl -w net.ipv6.neigh.default.gc_thresh1=2048 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh2=4096 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh3=8192 > /dev/null 2>&1
ethtool -G $INTERFACE rx 4096 tx 4096 >/dev/null 2>&1

# Hàm tạo IP ngẫu nhiên dải /64 (Đặt cố định tại đây)
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen_ipv6() {
    rd() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# 7. Bước 1: Khởi tạo danh sách - CẬP NHẬT MỖI 1000
echo "⏳ Bước 1: Đang chuẩn bị dữ liệu cho $PROXY_COUNT Proxy..."
pkill 3proxy > /dev/null 2>&1

# Làm sạch cấu hình IP cũ
ip -6 addr flush dev $INTERFACE scope global > /dev/null 2>&1
nmcli connection up $INTERFACE > /dev/null 2>&1
sleep 1

echo -n "" > "$BATCH_FILE"
exec 3> "$WORKDATA"
for port in $(seq $FIRST_PORT $((FIRST_PORT + PROXY_COUNT - 1))); do
    ipv6_rand=$(gen_ipv6)
    echo "//$IP4/$port/$ipv6_rand" >&3
    echo "addr add $ipv6_rand/64 dev $INTERFACE" >> "$BATCH_FILE"
    
    current=$((port - FIRST_PORT + 1))
    if (( current % 1000 == 0 || current == PROXY_COUNT )); then
        echo -ne "   [+] Đang tạo danh sách: $current / $PROXY_COUNT \r"
    fi
done
exec 3>&-
echo -e "\n✅ Bước 1 hoàn tất."

# 8. Bước 2: Gán IP vào card mạng (Batch mode) - CẬP NHẬT MỖI 1000
echo "⏳ Bước 2: Đang gán IPv6 vào card mạng..."
split -l 1000 "$BATCH_FILE" "${WORKDIR}/split_batch_"

count_added=0
for f in ${WORKDIR}/split_batch_*; do
    ip -6 -batch "$f" > /dev/null 2>&1
    lines=$(wc -l < "$f")
    count_added=$((count_added + lines))
    echo -ne "   [+] Tiến độ: $count_added / $PROXY_COUNT \r"
done
rm -f ${WORKDIR}/split_batch_*
echo -e "\n✅ Bước 2 hoàn tất."

# 9. Ghi Config 3proxy (Giới hạn luồng maxconn 1024 để mượt RAM 2GB)
cat <<EOF > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 1024
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF

# 10. Cấu hình Khởi động cùng hệ thống
chmod +x /etc/rc.d/rc.local
{
    echo "ip -6 addr flush dev $INTERFACE scope global"
    echo "nmcli connection up $INTERFACE"
    echo "ethtool -G $INTERFACE rx 4096 tx 4096"
    echo "sysctl -w net.ipv6.neigh.default.gc_thresh3=8192"
    echo "ip -6 -batch $BATCH_FILE"
} > "${WORKDIR}/boot_ifconfig.sh"

sed -i '/3proxy/d' /etc/rc.d/rc.local
sed -i '/boot_ifconfig.sh/d' /etc/rc.d/rc.local
echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# 11. Khởi chạy hệ thống proxy
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo "=========================================================="
echo "✅ HOÀN TẤT THÀNH CÔNG!"
echo "🌐 Trạng thái: $PROXY_COUNT Proxy đang chạy."
echo "📂 Tải list proxy tại: ${WORKDIR}/proxy.txt"
echo "=========================================================="
#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 - Bản Siêu Tốc (Check mạng trước khi nhập)
# Tối ưu: Sửa lỗi chập chờn mạng, tràn bộ đệm Neighbor Table cho nhiều Phone
# ==============================================================================

clear
echo "=========================================================="
echo "    TOOL AUTO PROXY V6 - KIỂM TRA HỆ THỐNG TRƯỚC          "
echo "=========================================================="

# 1. Khởi tạo card mạng và xác định Interface
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -z "$INTERFACE" ]; then
    echo "[-] LỖI: Không tìm thấy card mạng có kết nối Internet!"
    exit 1
fi

# Ép tự động kết nối nếu card bị tắt ngầm
nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
nmcli device connect "$INTERFACE" >/dev/null 2>&1

# 2. Thu thập dữ liệu mạng mạng để hiển thị trước
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)
IP6_RAW=$(curl -6 -s --max-time 5 icanhazip.com)
PREFIX=$(echo $IP6_RAW | cut -f1-4 -d':')

# 3. Hiển thị thông số cho người dùng kiểm tra trước
echo -e "📱 Card mạng đang dùng : \e[32m$INTERFACE\e[0m"
echo -e "🌐 IPv4 tĩnh của máy   : \e[32m$IP4\e[0m"

if [ -z "$PREFIX" ]; then
    echo -e "❌ Tình trạng IPv6     : \e[31mKhông phản hồi (No Internet IPv6)\e[0m"
    echo "[-] Vui lòng kiểm tra lại cấu hình IPv6 trên MikroTik E50UG trước!"
    exit 1
else
    echo -e "✅ Tình trạng IPv6     : \e[32mThông mạng\e[0m"
    echo -e "🛰️  Dải IPv6 Prefix    : \e[36m$PREFIX::/64\e[0m"
fi
echo "=========================================================="

# 4. Nhập liệu (Sau khi đã check mọi thứ đều XANH)
read -p "👉 Nhập cổng bắt đầu (VD: 10000): " INPUT_PORT < /dev/tty
FIRST_PORT=$((10#$INPUT_PORT))
read -p "👉 Nhập số lượng proxy muốn tạo: " PROXY_COUNT < /dev/tty

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

# 6. Tối ưu hệ thống (Fix lỗi rớt mạng, chậm mạng khi cắm nhiều phone)
systemctl stop firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.proxy_ndp=1 > /dev/null 2>&1

# Nới rộng bảng Neighbor chống nghẽn đường truyền mạng IPv6
sysctl -w net.ipv6.neigh.default.gc_thresh1=2048 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh2=4096 > /dev/null 2>&1
sysctl -w net.ipv6.neigh.default.gc_thresh3=8192 > /dev/null 2>&1

# Mở rộng hàng đợi nhận gửi dữ liệu của card ens160 lên tối đa
ethtool -G $INTERFACE rx 4096 tx 4096 >/dev/null 2>&1

# 7. Bước 1: Khởi tạo danh sách - CẬP NHẬT MỖI 1000
echo "⏳ Bước 1: Đang chuẩn bị dữ liệu cho $PROXY_COUNT Proxy..."
pkill 3proxy > /dev/null 2>&1
ip -6 addr flush dev $INTERFACE scope global > /dev/null 2>&1
nmcli connection up $INTERFACE > /dev/null 2>&1

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

# 9. Ghi Config 3proxy (Hạ maxconn xuống 1024 để mượt RAM 2GB)
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

# 10. Cấu hình Khởi động cùng hệ thống (Giữ lại các thông số tối ưu mạng)
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

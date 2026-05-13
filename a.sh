#!/bin/bash

# ==============================================================================
# Script: Auto Proxy IPv6 /64 - Siêu Tốc (Batch Mode + Double Progress Bar)
# Tối ưu: Rocky Linux, gán hàng nghìn IP trong vài giây
# ==============================================================================

# 1. Khởi tạo card mạng
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null)
if [ -n "$INTERFACE" ]; then
    nmcli connection modify "$INTERFACE" connection.autoconnect yes >/dev/null 2>&1
    nmcli device connect "$INTERFACE" >/dev/null 2>&1
fi

clear
echo "=========================================================="
echo "    TOOL AUTO PROXY V6 - PHIÊN BẢN SIÊU TỐC (BATCH)      "
echo "=========================================================="

# 2. Nhập liệu (Lưu ý: Port nên > 1024)
read -p "Nhập cổng bắt đầu (VD: 10000): " INPUT_PORT < /dev/tty
FIRST_PORT=$((10#$INPUT_PORT))
read -p "Nhập số lượng proxy: " PROXY_COUNT < /dev/tty

WORKDIR="/home/proxy-v6"
WORKDATA="${WORKDIR}/data.txt"
BATCH_FILE="${WORKDIR}/ip_batch.txt"
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

# 4. Tối ưu hệ thống
systemctl stop firewalld > /dev/null 2>&1
setenforce 0 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1
sysctl -w net.ipv6.conf.all.proxy_ndp=1 > /dev/null 2>&1

# 5. Lấy Prefix IPv6
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)
IP6_RAW=$(curl -6 -s icanhazip.com)
PREFIX=$(echo $IP6_RAW | cut -f1-4 -d':')

if [ -z "$PREFIX" ]; then
    echo "[-] LỖI: Không lấy được IPv6! Kiểm tra kết nối mạng."
    exit 1
fi

# 6. Hàm tạo IP ngẫu nhiên
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen_ipv6() {
    rd() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$PREFIX:$(rd):$(rd):$(rd):$(rd)"
}

# 7. Bước 1: Khởi tạo danh sách & File Batch (Có tiến độ)
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
    
    if (( port % 100 == 0 || port == (FIRST_PORT + PROXY_COUNT - 1) )); then
        current=$((port - FIRST_PORT + 1))
        echo -ne "   [+] Đang tạo danh sách: $current / $PROXY_COUNT \r"
    fi
done
exec 3>&-
echo -e "\n✅ Bước 1 hoàn tất."

# 8. Bước 2: Gán IP vào hệ thống (Batch mode + Progress)
echo "⏳ Bước 2: Đang gán IPv6 vào card mạng..."
# Chia nhỏ file batch thành từng gói 500 IP để hiển thị tiến độ nhảy số
split -l 500 "$BATCH_FILE" "${WORKDIR}/split_batch_"

count_added=0
for f in ${WORKDIR}/split_batch_*; do
    ip -6 -batch "$f" > /dev/null 2>&1
    lines=$(wc -l < "$f")
    count_added=$((count_added + lines))
    echo -ne "   [+] Tiến độ: $count_added / $PROXY_COUNT \r"
done
rm -f ${WORKDIR}/split_batch_*
echo -e "\n✅ Bước 2 hoàn tất: Đã kích hoạt $count_added IPv6."

# 9. Ghi Config 3proxy
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

# 10. Cấu hình tự chạy khi Reboot
echo "⏳ Bước 3: Thiết lập khởi động cùng hệ thống..."
chmod +x /etc/rc.d/rc.local
echo "ip -6 addr flush dev $INTERFACE scope global" > "${WORKDIR}/boot_ifconfig.sh"
echo "nmcli connection up $INTERFACE" >> "${WORKDIR}/boot_ifconfig.sh"
echo "ip -6 -batch $BATCH_FILE" >> "${WORKDIR}/boot_ifconfig.sh"

sed -i '/3proxy/d' /etc/rc.d/rc.local
sed -i '/boot_ifconfig.sh/d' /etc/rc.d/rc.local
echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local

# 11. Khởi chạy 3proxy
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo "=========================================================="
echo "✅ HOÀN TẤT!"
echo "🌐 Trạng thái: $PROXY_COUNT Proxy đang chạy."
echo "📂 Danh sách: ${WORKDIR}/proxy.txt"
echo "=========================================================="

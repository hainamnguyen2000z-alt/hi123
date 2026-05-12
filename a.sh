#!/bin/bash
# ==============================================================================
# Script: Auto Setup IPv6 Proxy (3proxy)
# Description: Tự động cài đặt 3proxy và tạo hàng loạt Proxy IPv6
# Author: Tên_Của_Bạn_Hoặc_Github_ID
# Version: 1.0
# ==============================================================================

GREEN='\03引[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Kiểm tra quyền Root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[-] Script này cần được chạy bằng quyền Root! Vui lòng dùng lệnh 'sudo -i' rồi chạy lại.${NC}"
    exit 1
fi

clear
echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   AUTO SETUP & CREATE PROXY IPV6 - GITHUB VERSION        ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""

# 1. Xử lý tham số đầu vào hoặc hỏi người dùng (Hỗ trợ chạy qua curl piped)
if [ -n "$1" ] && [ -n "$2" ]; then
    FIRST_PORT=$1
    PROXY_COUNT=$2
else
    while true; do
        read -p "Nhập cổng bắt đầu (Ví dụ: 10000): " INPUT_PORT < /dev/tty
        FIRST_PORT=$((10#$INPUT_PORT))
        if [[ "$FIRST_PORT" -ge 1 && "$FIRST_PORT" -le 65535 ]]; then
            break
        else
            echo -e "${RED}-> LỖI: Cổng không hợp lệ! Nhập từ 1 đến 65535.${NC}"
        fi
    done

    while true; do
        read -p "Nhập số lượng proxy muốn tạo (Tối đa 60000): " PROXY_COUNT < /dev/tty
        if [[ "$PROXY_COUNT" -gt 0 && "$PROXY_COUNT" -le 60000 ]]; then
            if [[ $((FIRST_PORT + PROXY_COUNT - 1)) -le 65535 ]]; then
                break
            else
                echo -e "${RED}-> LỖI: Cổng kết thúc vượt quá 65535. Hãy giảm số lượng!${NC}"
            fi
        else
            echo -e "${RED}-> LỖI: Số lượng không hợp lệ!${NC}"
        fi
    done
fi

LAST_PORT=$((FIRST_PORT + PROXY_COUNT - 1))
WORKDIR="/home/proxy-v6"
WORKDATA="${WORKDIR}/data.txt"

# 2. Dọn dẹp máy chủ và Flush IPv6 cũ
echo -e "${YELLOW}⏳ Đang dọn dẹp hệ thống và làm sạch IP cũ...${NC}"
pkill 3proxy > /dev/null 2>&1
INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
ip -6 addr flush dev $INTERFACE scope global
systemctl restart NetworkManager
sleep 3
echo -e "${GREEN}✅ Dọn dẹp hệ thống thành công!${NC}"

# 3. Tự động cài đặt nếu máy mới tinh chưa có 3proxy
if [ ! -f "/usr/local/etc/3proxy/bin/3proxy" ]; then
    echo -e "${YELLOW}⏳ Đang tải thư viện và biên dịch 3proxy...${NC}"
    dnf install wget tar zip curl nano git make gcc net-tools -y > /dev/null 2>&1
    cd /root || exit
    rm -rf 3proxy-*
    wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz
    tar xzf 0.9.4.tar.gz
    cd 3proxy-0.9.4 || exit
    make -f Makefile.Linux > /dev/null 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp bin/3proxy /usr/local/etc/3proxy/bin/
    chmod +x /usr/local/etc/3proxy/bin/3proxy
fi

# 4. Tối ưu Kernel và Firewall
echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/99-ipv6.conf
echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.d/99-ipv6.conf
echo "net.ipv6.conf.all.proxy_ndp=1" >> /etc/sysctl.d/99-ipv6.conf
echo "net.ipv6.conf.default.proxy_ndp=1" >> /etc/sysctl.d/99-ipv6.conf
sysctl -p /etc/sysctl.d/99-ipv6.conf > /dev/null 2>&1
systemctl stop firewalld > /dev/null 2>&1
systemctl disable firewalld > /dev/null 2>&1

# 5. Cập nhật thông tin mạng
IP4=$(ip -4 addr show $INTERFACE | grep inet | awk '{print $2}' | cut -d/ -f1)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

if [ -z "$IP6" ]; then
    echo -e "${RED}[-] LỖI: Không tìm thấy IPv6! Đảm bảo Router/VPS đã cấp IPv6.${NC}"
    exit 1
fi

echo -e "=> Giao diện mạng : ${GREEN}$INTERFACE${NC}"
echo -e "=> IP LAN (IPv4)  : ${GREEN}$IP4${NC}"
echo -e "=> Dải IPv6 MỚI   : ${GREEN}$IP6::/64${NC}"
echo "---------- BẮT ĐẦU TẠO $PROXY_COUNT PROXY ----------"

mkdir -p $WORKDIR
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() { echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"; }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# 6. Tính toán Proxy và IP ảo
count=0
exec 3> "$WORKDATA"
exec 4> "${WORKDIR}/boot_ifconfig.sh"

for port in $(seq $FIRST_PORT $LAST_PORT); do
    ipv6_rand=$(gen64 "$IP6")
    echo "//$IP4/$port/$ipv6_rand" >&3
    echo "ip -6 addr add $ipv6_rand/64 dev $INTERFACE" >&4
    count=$((count + 1))
    if (( count % 50 == 0 || count == PROXY_COUNT )); then
        echo -ne "⏳ Đang tính toán dữ liệu: $count / $PROXY_COUNT proxy \r"
    fi
done
echo -ne "✅ Đang tính toán dữ liệu: $PROXY_COUNT / $PROXY_COUNT proxy \n"
exec 3>&-
exec 4>&-

# 7. Nạp IP vào card mạng
chmod +x ${WORKDIR}/boot_ifconfig.sh
added=0
while IFS= read -r cmd; do
    $cmd 2>/dev/null
    added=$((added + 1))
    if (( added % 50 == 0 || added == PROXY_COUNT )); then
        echo -ne "⏳ Đang nạp IP vào hệ thống: $added / $PROXY_COUNT IP \r"
    fi
done < "${WORKDIR}/boot_ifconfig.sh"
echo -ne "✅ Đang nạp IP vào hệ thống: $PROXY_COUNT / $PROXY_COUNT IP \n"

# 8. Cấu hình 3proxy
cat <<EOF_PROXY > /usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 10000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2606:4700:4700::1111
nserver 2001:4860:4860::8888
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth none
allow *
$(awk -F "/" '{print "proxy -6 -n -a -p"$4" -i"$3" -e"$5}' ${WORKDATA})
EOF_PROXY

# 9. Ghi đè file khởi động Boot
sed -i '/3proxy/d' /etc/rc.d/rc.local
sed -i '/boot_ifconfig.sh/d' /etc/rc.d/rc.local
sed -i '/ulimit -n/d' /etc/rc.d/rc.local
echo "ulimit -n 999999" >> /etc/rc.d/rc.local
echo "bash ${WORKDIR}/boot_ifconfig.sh" >> /etc/rc.d/rc.local
echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg" >> /etc/rc.d/rc.local
chmod +x /etc/rc.d/rc.local

# 10. Chạy 3proxy và Xuất file
ulimit -n 999999
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
awk -F "/" '{print $3":"$4}' ${WORKDATA} > ${WORKDIR}/proxy.txt

echo ""
echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}    [+] HOÀN TẤT QUÁ TRÌNH TẠO PROXY!                     ${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo -e "Danh sách Proxy được lưu tại: ${YELLOW}${WORKDIR}/proxy.txt${NC}"
echo "----------------------------------------------------------"
head -n 5 ${WORKDIR}/proxy.txt
echo "..."
echo "----------------------------------------------------------"
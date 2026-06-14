cat << 'EOF' > /root/a.sh
#!/bin/bash

# 1. Định nghĩa các đường dẫn hệ thống
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
SCRIPT_FIX="/usr/local/bin/check_and_fix_proxy.sh"
BIN_3PROXY="/usr/local/bin/3proxy"

# 2. Tự động tải file chạy 3proxy chuẩn nếu hệ thống chưa có
if [ ! -f "$BIN_3PROXY" ]; then
    echo "[+] Đang tải file chạy 3proxy chuẩn cho Rocky Linux..."
    mkdir -p /usr/local/bin
    curl -sL https://raw.githubusercontent.com/hainamnguyen2000z-alt/hi123/refs/heads/main/3proxy -o "$BIN_3PROXY"
    chmod +x "$BIN_3PROXY"
fi

# 3. Lấy thông tin mạng mạng vật lý
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    echo "[!] Không tìm thấy card mạng chính. Dừng cấu hình."
    exit 1
fi

# Tự động dò dải IPv6 WAN từ Router MikroTik cấp xuống
SRC_PREFIX=$(ip -6 addr show dev $INTERFACE | grep "scope global" | grep -v "deprecated" | awk '{print $2}' | cut -d'/' -f1 | head -n 1 | cut -d':' -f1-4)
if [ -z "$SRC_PREFIX" ]; then
    echo "[!] Không tìm thấy dải IPv6 WAN từ Router. Hãy kiểm tra lại kết nối Bridge."
    exit 1
fi

# 4. Nhập số lượng port muốn tạo
clear
echo "=========================================================================="
echo "          HỆ THỐNG KHỞI TẠO ĐA PROXY IPV6 TỰ ĐỘNG CHUẨN LAN 0.0.0.0       "
echo "=========================================================================="
read -p "[?] Nhập số lượng Proxy IPv6 muốn tạo (Tối thiểu là 1000): " PROXY_COUNT

if [[ ! "$PROXY_COUNT" =~ ^[0-9]+$ ]] || [ "$PROXY_COUNT" -lt 1000 ]; then
    echo "[!] Số lượng không hợp lệ. Thiết lập mặc định: 1000 port."
    PROXY_COUNT=1000
fi

START_PORT=10001
END_PORT=$((START_PORT + PROXY_COUNT - 1))

# Tắt sạch dịch vụ cũ trước khi cấu hình mới
pkill -9 3proxy
pkill -9 -f check_and_fix_proxy
rm -f "$CONFIG_FILE"
ip -6 addr flush dev $INTERFACE scope global >/dev/null 2>&1

# 5. Sinh file cấu hình 3proxy.cfg chuẩn (Mở cổng mạng LAN 0.0.0.0)
mkdir -p $(dirname "$CONFIG_FILE")
cat << EOT > "$CONFIG_FILE"
daemon
maxconn 4000
nscache 65536
timeouts 1 5 30 60 180 15 60 30
setgid 115
setuid 115
flush
auth none
EOT

echo "[+] Đang tính toán sinh nhanh chuỗi cấu hình và gán IP..."
# Vòng lặp tối ưu sinh IP cực nhanh trực tiếp trên RAM và đẩy vào file config
for ((port=$START_PORT; port<=$END_PORT; port++)); do
    NEW_IPV6="${SRC_PREFIX}:$(printf '%x:%x:%x:%x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))"
    # Gán IP nền vào card mạng
    ip -6 addr add ${NEW_IPV6}/64 dev $INTERFACE >/dev/null 2>&1
    # -i0.0.0.0: Mở cổng ra ngoài mạng LAN để Proxy Helper kết nối được
    echo "proxy -6 -n -a -p$port -i0.0.0.0 -e$NEW_IPV6" >> "$CONFIG_FILE"
done

# 6. Khởi động dịch vụ 3proxy
"$BIN_3PROXY" "$CONFIG_FILE" >/dev/null 2>&1

# 7. Sinh script tự động check và bảo trì proxy ngầm
cat << 'EOF_FIX' > "$SCRIPT_FIX"
#!/bin/bash
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
BIN_3PROXY="/usr/local/bin/3proxy"
if ! pgrep -x "3proxy" > /dev/null; then
    "$BIN_3PROXY" "$CONFIG_FILE" >/dev/null 2>&1
fi
EOF_FIX
chmod +x "$SCRIPT_FIX"

# Thêm vào crontab để tự động check mỗi phút một lần
(crontab -l 2>/dev/null | grep -v "check_and_fix_proxy"; echo "* * * * * $SCRIPT_FIX") | crontab -

echo "=========================================================================="
echo "[+] HOÀN THÀNH: Đã khởi tạo thành công $PROXY_COUNT proxy!"
echo "[+] Cổng chạy từ: $START_PORT đến $END_PORT"
echo "[+] Trạng thái cổng kết nối mạng LAN hiện tại:"
echo "=========================================================================="
ss -tulpn | grep 3proxy | head -n 5
echo "... và các port tiếp theo."
EOF
sed -i 's/\r$//' /root/a.sh
chmod +x /root/a.sh
./a.sh

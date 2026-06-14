#!/bin/bash

# ==========================================================================
# SCRIPT 2000 PROXY ĐỘC LẬP (1 PORT = 1 IPV6) - CẤU HÌNH 2 vCPU / 2GB RAM
# Cơ chế: Check thực tế qua ifconfig.me - Giới hạn tối đa 20 luồng chạy song song
# Chu kỳ quét: Cứ mỗi 5 phút một lần
# ==========================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Vui long chay script voi quyen root (sudo ./a.sh)"
  exit 1
fi

echo "[+] Dang toi uu hoa thong so he thong chiu tai cho 2000 Proxy..."

# 1. Tu dong lay Interface mang chinh
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    echo "[-] Khong tim thay interface mang hop le."
    exit 1
fi

# 2. Toi uu han muc File Descriptors va Bo nho dem IPv6 cua Kernel
ulimit -n 250000
if ! grep -q "soft nofile 250000" /etc/security/limits.conf; then
cat <<EOF >> /etc/security/limits.conf
* soft nofile 250000
* hard nofile 250000
root soft nofile 250000
root hard nofile 250000
EOF
fi

cp /etc/sysctl.conf /etc/sysctl.conf.bak >/dev/null 2>&1
sed -i '/net.ipv4.ip_local_port_range/d; /net.ipv4.tcp_tw_reuse/d; /net.core.somaxconn/d; /net.ipv4.tcp_max_syn_backlog/d; /net.ipv6.route.max_size/d; /max_addresses/d' /etc/sysctl.conf

cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv6.route.max_size = 262144
net.ipv6.conf.all.max_addresses = 10000
net.ipv6.conf.$INTERFACE.max_addresses = 10000
EOF
sysctl -p >/dev/null 2>&1
sysctl -w net.ipv6.conf.$INTERFACE.use_tempaddr=0 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.use_tempaddr=0 >/dev/null 2>&1

# --------------------------------------------------------------------------
# 3. KHOI TAO CODE CHECK LIVE/DIE CHIA LUỒNG (MAX 20 RUNNING JOBS)
# --------------------------------------------------------------------------
MONITOR_SCRIPT="/usr/local/bin/check_and_fix_proxy.sh"

cat << 'EOF' > $MONITOR_SCRIPT
#!/bin/bash

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
LOG_FILE="/var/log/proxy_check.log"
DIE_LIST_FILE="/tmp/proxy_died_ports.txt"

# --- CAU HINH THONG SO PROXY CUA BAN ---
START_PORT=10001
END_PORT=12000
PROXY_USER="user_cua_ban"
PROXY_PASS="pass_cua_ban"
MAX_THREADS=20 # Ép hệ thống chạy đúng tối đa 20 luồng kiểm tra song song
# ---------------------------------------

gen_ipv6_suffix() {
    printf '%x:%x:%x:%x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

# Lấy dải IPv6 Prefix hiện tại từ E50UG
IPV6_PREFIX=$(ip -6 addr show dev $INTERFACE | grep "scope global" | grep -v "deprecated" | awk '{print $2}' | cut -d'/' -f1 | head -n 1 | cut -d':' -f1-4)

if [ -z "$IPV6_PREFIX" ] || [ ${#IPV6_PREFIX} -lt 10 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Khong lay duoc IPv6 Prefix tu E50UG!" >> $LOG_FILE
    exit 1
fi

# Khởi tạo file cấu hình gốc nếu chưa có
if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p $(dirname "$CONFIG_FILE")
    cat <<EOT > $CONFIG_FILE
daemon
maxconn 4000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER
EOT
    # Sinh tạm 2000 port ban đầu nếu chưa từng chạy
    for ((port=$START_PORT; port<=$END_PORT; port++)); do
        NEW_IPV6="${IPV6_PREFIX}:$(gen_ipv6_suffix)"
        ip -6 addr add $NEW_IPV6/64 dev $INTERFACE >/dev/null 2>&1
        echo "proxy -6 -n -a -p$port -i127.0.0.1 -e$NEW_IPV6" >> $CONFIG_FILE
    done
    pkill -9 3proxy && sleep 1
    /usr/local/bin/3proxy $CONFIG_FILE >/dev/null 2>&1 &
    exit 0
fi

# Làm sạch file chứa danh sách port bị die trước khi check
> $DIE_LIST_FILE

# Hàm xử lý kiểm tra cho một Port đơn lẻ (Được gọi hàng loạt bởi xargs)
export -f gen_ipv6_suffix
check_single_port() {
    local port=$1
    local user=$2
    local pass=$3
    local die_file=$4
    
    # Gửi request kiểm tra IP thực tế qua ifconfig.me (Giới hạn timeout kết nối ngắn 4 giây)
    CHECK_IP=$(curl -6 -s --proxy http://$user:$pass@127.0.0.1:$port http://ifconfig.me --connect-timeout 4)
    
    if [ -z "$CHECK_IP" ]; then
        # Nếu die, ghi port này vào danh sách hàng đợi xử lý
        echo "$port" >> $die_file
    fi
}
export -f check_single_port

echo "[*] Dang tiến hành quet song song 20 luong cho 2000 ports proxy..."

# Sử dụng xargs phối hợp kiểm tra giới hạn đúng 20 luồng chạy song song
seq $START_PORT $END_PORT | xargs -n 1 -P $MAX_THREADS -I {} bash -c 'check_single_port "{}" "'"$PROXY_USER"'" "'"$PROXY_PASS"'" "'"$DIE_LIST_FILE"'"'

# Sau khi quét xong, kiểm tra xem có port nào bị die không
if [ -s $DIE_LIST_FILE ]; then
    NEED_RESTART=0
    
    # Đọc danh sách các port bị báo die để sửa đổi cấu hình
    while read -r died_port; do
        if [ -n "$died_port" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DIE: Port $died_port khong phan hoi. Dang cấp IPv6 moi..." >> $LOG_FILE
            
            # Sinh IPv6 mới
            NEW_IPV6="${IPV6_PREFIX}:$(printf '%x:%x:%x:%x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))"
            
            # Nạp IP mới vào card mạng Linux
            ip -6 addr add $NEW_IPV6/64 dev $INTERFACE >/dev/null 2>&1
            
            # Thay thế dòng cấu hình cũ của riêng port đó trong file 3proxy.cfg
            sed -i "/-p$died_port /d" $CONFIG_FILE
            echo "proxy -6 -n -a -p$died_port -i127.0.0.1 -e$NEW_IPV6" >> $CONFIG_FILE
            
            NEED_RESTART=1
        fi
    done < $DIE_LIST_FILE
    
    # Áp dụng khởi động lại dịch vụ mượt mà nếu có thay đổi
    if [ $NEED_RESTART -eq 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESTART: Nap lai cau hinh moi cho cac port bi loi..." >> $LOG_FILE
        if systemctl list-unit-files | grep -q "3proxy.service"; then
            systemctl restart 3proxy
        else
            pkill -9 3proxy
            /usr/local/bin/3proxy $CONFIG_FILE >/dev/null 2>&1 &
        fi
    fi
fi
EOF

chmod +x $MONITOR_SCRIPT

# --------------------------------------------------------------------------
# 4. ĐĂNG KÝ VÀO CRONTAB CHẠY TỰ ĐỘNG MỖI 5 PHÚT
# --------------------------------------------------------------------------
echo "[+] Dang ky vao lich trinh hệ thống Crontab..."
crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * $MONITOR_SCRIPT >/dev/null 2>&1") | crontab -

# Chạy kích hoạt lần đầu tiên ngay lập tức
echo "[+] Khởi tạo quét kiểm tra và kích hoạt hệ thống ban đầu..."
bash $MONITOR_SCRIPT

echo "=========================================================================="
echo "[+] HOAN THANH: He thong Multi-threading 20 Luong da thiet lap!"
echo "[+] Thoi gian tu dong quet kiem tra lai danh sach: 5 phut / lan."
echo "[+] Log giam sat thuc te luu tai: /var/log/proxy_check.log"
echo "=========================================================================="

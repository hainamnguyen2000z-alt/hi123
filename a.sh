#!/bin/bash

# ==========================================================================
# SCRIPT PROXY ĐỘC LẬP (1 PORT = 1 IPV6) - FIX MẶC ĐỊNH START PORT 10001
# Tối ưu cấu hình chịu tải cao cho VM 2GB RAM / 2 vCPU + MikroTik E50UG
# Cơ chế: Check live/die 20 luồng song song qua xargs mỗi 5 phút
# ==========================================================================

if [ "$EUID" -ne 0 ]; then
  echo "[-] Vui long chay script voi quyen root (sudo ./a.sh)"
  exit 1
fi

# --------------------------------------------------------------------------
# BƯỚC NHẬP SỐ LƯỢNG PROXY TỪ BÀN PHÍM (BẮT BUỘC TỐI THIỂU 1000 PORT)
# --------------------------------------------------------------------------
echo "=========================================================================="
echo "                   CẤU HÌNH SỐ LƯỢNG PROXY DỰ ÁN                          "
echo "=========================================================================="
while true; do
    read -p "[?] Nhập số lượng Proxy IPv6 muốn tạo (Tối thiểu là 1000): " PROXY_COUNT
    
    # Kiểm tra tính hợp lệ của dữ liệu nhập vào (phải là số nguyên)
    if [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]]; then
        if [ "$PROXY_COUNT" -ge 1000 ]; then
            echo "[+] Hợp lệ! Hệ thống sẽ khởi tạo $PROXY_COUNT Proxy."
            break
        else
            echo "[-] Sai quy định: Số lượng port tối thiểu phải là 1000. Vui lòng nhập lại!"
        fi
    else
        echo "[-] Lỗi: Cần nhập vào một số nguyên hợp lệ."
    fi
done

# CẤU HÌNH CỐ ĐỊNH PORT BẮT ĐẦU TỪ 10001
START_PORT=10001
END_PORT=$((START_PORT + PROXY_COUNT - 1))

# --- CẤU HÌNH TÀI KHOẢN PROXY CỦA BẠN ---
PROXY_USER="user_cua_ban"
PROXY_PASS="pass_cua_ban"
# ----------------------------------------

echo "[+] BTD: Bat dau cau hinh va toi uu hoa he thong..."

# Tự động lấy Interface mạng chính
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    echo "[-] Khong tim thay interface mang hop le."
    exit 1
fi

# --------------------------------------------------------------------------
# 1. TỐI ƯU NHÂN KERNEL LINUX & FILE DESCRIPTORS (TỰ ĐỘNG THEO SỐ PORT)
# --------------------------------------------------------------------------
# Tính toán số lượng giới hạn file mở để tránh lỗi "Too many open files"
MAX_FILES=$((PROXY_COUNT * 10 + 50000))
ulimit -n $MAX_FILES

if ! grep -q "soft nofile $MAX_FILES" /etc/security/limits.conf; then
cat <<EOF >> /etc/security/limits.conf
* soft nofile $MAX_FILES
* hard nofile $MAX_FILES
root soft nofile $MAX_FILES
root hard nofile $MAX_FILES
EOF
fi

cp /etc/sysctl.conf /etc/sysctl.conf.bak >/dev/null 2>&1
sed -i '/net.ipv4.ip_local_port_range/d; /net.ipv4.tcp_tw_reuse/d; /net.core.somaxconn/d; /net.ipv4.tcp_max_syn_backlog/d; /net.ipv6.route.max_size/d; /max_addresses/d' /etc/sysctl.conf

# Cấu hình bộ nhớ đệm card mạng dựa trên quy mô số lượng proxy đã nhập
MAX_ADDR=$((PROXY_COUNT * 2))
cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv6.route.max_size = 262144
net.ipv6.conf.all.max_addresses = $MAX_ADDR
net.ipv6.conf.$INTERFACE.max_addresses = $MAX_ADDR
EOF
sysctl -p >/dev/null 2>&1

# Khóa tính năng tự sinh IP ngẫu nhiên gây rác mạng của Linux OS
sysctl -w net.ipv6.conf.$INTERFACE.use_tempaddr=0 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.use_tempaddr=0 >/dev/null 2>&1

# --------------------------------------------------------------------------
# 2. ĐÓNG GÓI SCRIPT GIÁM SÁT ĐA LUỒNG CHẠY NGẦM (MỖI 5 PHÚT)
# --------------------------------------------------------------------------
MONITOR_SCRIPT="/usr/local/bin/check_and_fix_proxy.sh"
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
LOG_FILE="/var/log/proxy_check.log"
DIE_LIST_FILE="/tmp/proxy_died_ports.txt"

cat << EOF > $MONITOR_SCRIPT
#!/bin/bash

INTERFACE=$INTERFACE
CONFIG_FILE="$CONFIG_FILE"
LOG_FILE="$LOG_FILE"
DIE_LIST_FILE="$DIE_LIST_FILE"

START_PORT=$START_PORT
END_PORT=$END_PORT
PROXY_USER="$PROXY_USER"
PROXY_PASS="$PROXY_PASS"
MAX_THREADS=20 

# Tìm dải IPv6 Prefix global thực tế được cấp từ E50UG
SRC_PREFIX=\$(ip -6 addr show dev \$INTERFACE | grep "scope global" | grep -v "deprecated" | awk '{print \$2}' | cut -d'/' -f1 | head -n 1 | cut -d':' -f1-4)

if [ -z "\$SRC_PREFIX" ] || [ \${#SRC_PREFIX} -lt 10 ]; then
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Khong lay duoc IPv6 Prefix tu E50UG!" >> \$LOG_FILE
    exit 1
fi

# Nếu hệ thống chạy lần đầu hoặc file config bị mất, tiến hành tạo mới toàn bộ
if [ ! -f "\$CONFIG_FILE" ]; then
    mkdir -p \$(dirname "\$CONFIG_FILE")
    cat <<EOT > \$CONFIG_FILE
daemon
maxconn 4000
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users \$PROXY_USER:CL:\$PROXY_PASS
allow \$PROXY_USER
EOT
    echo "[*] Thiet lap co ban ban dau cho \$((END_PORT - START_PORT + 1)) ports..."
    for ((port=\$START_PORT; port<=\$END_PORT; port++)); do
        NEW_IPV6="\${SRC_PREFIX}:\$(printf '%x:%x:%x:%x' \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)))"
        ip -6 addr add \$NEW_IPV6/64 dev \$INTERFACE >/dev/null 2>&1
        echo "proxy -6 -n -a -p\$port -i127.0.0.1 -e\$NEW_IPV6" >> \$CONFIG_FILE
    done
    pkill -9 3proxy && sleep 1
    /usr/local/bin/3proxy \$CONFIG_FILE >/dev/null 2>&1 &
    exit 0
fi

> \$DIE_LIST_FILE

check_single_port() {
    local port=\$1
    local user=\$2
    local pass=\$3
    local die_file=\$4
    CHECK_IP=\$(curl -6 -s --proxy http://\$user:\$pass@127.0.0.1:\$port http://ifconfig.me --connect-timeout 4)
    if [ -z "\$CHECK_IP" ]; then
        echo "\$port" >> \$die_file
    fi
}
export -f check_single_port

# Thực thi quét đa luồng qua xargs, giới hạn chuẩn đúng 20 luồng đồng thời bảo vệ RAM
seq \$START_PORT \$END_PORT | xargs -n 1 -P \$MAX_THREADS -I {} bash -c 'check_single_port "{}" "'"\$PROXY_USER"'" "'"\$PROXY_PASS"'" "'"\$DIE_LIST_FILE"'"'

# Chỉ sửa đổi trúng đích các port bị phát hiện đã die rớt mạng
if [ -s \$DIE_LIST_FILE ]; then
    NEED_RESTART=0
    while read -r died_port; do
        if [ -n "\$died_port" ]; then
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] DIE: Port \$died_port khong phan hoi. Dang lam moi IPv6..." >> \$LOG_FILE
            NEW_IPV6="\${SRC_PREFIX}:\$(printf '%x:%x:%x:%x' \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)) \$((RANDOM%65536)))"
            
            # Gán IP mới đơn lẻ vào card mạng Linux
            ip -6 addr add \$NEW_IPV6/64 dev \$INTERFACE >/dev/null 2>&1
            
            # Khóa dòng config cũ và chèn cấu trúc IP mới độc lập cho port lỗi này
            sed -i "/-p\$died_port /d" \$CONFIG_FILE
            echo "proxy -6 -n -a -p\$died_port -i127.0.0.1 -e\$NEW_IPV6" >> \$CONFIG_FILE
            NEED_RESTART=1
        fi
    done < \$DIE_LIST_FILE
    
    if [ \$NEED_RESTART -eq 1 ]; then
        if systemctl list-unit-files | grep -q "3proxy.service"; then
            systemctl restart 3proxy
        else
            pkill -9 3proxy
            /usr/local/bin/3proxy \$CONFIG_FILE >/dev/null 2>&1 &
        fi
    fi
fi
EOF

chmod +x $MONITOR_SCRIPT

# --------------------------------------------------------------------------
# 3. ĐĂNG KÝ VÀO CRONTAB CHẠY TỰ ĐỘNG MỖI 5 PHÚT
# --------------------------------------------------------------------------
echo "[+] Dang ky vao lich trinh hệ thống Crontab..."
crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * $MONITOR_SCRIPT >/dev/null 2>&1") | crontab -

# Dọn dẹp dấu vết cấu hình cũ để ép hệ thống khởi chạy sạch sẽ theo số lượng mới nhập
rm -f $CONFIG_FILE
ip -6 addr flush dev $INTERFACE scope global >/dev/null 2>&1

echo "[+] Đang tiến hành tạo cấu hình gốc và cấp phát $PROXY_COUNT proxy, vui lòng đợi..."
bash $MONITOR_SCRIPT

echo "=========================================================================="
echo "[+] HOÀN THÀNH: Hệ thống vận hành Proxy Độc lập đã sẵn sàng!"
echo "[+] Mặc định cổng bắt đầu: $START_PORT"
echo "[+] Cổng kết thúc tự động tính toán: $END_PORT (Tổng cộng: $PROXY_COUNT cổng)"
echo "[+] Cơ chế quét sửa lỗi: Cứ mỗi 5 phút check song song đúng 20 luồng."
echo "[+] Đường dẫn log theo dõi: /var/log/proxy_check.log"
echo "=========================================================================="

#!/bin/bash

# ==========================================================================
# SCRIPT REAL-TIME MONITOR CHO HỆ THỐNG ĐA PROXY IPV6
# Hiển thị: Status, Tổng Port, Live/Die, Băng thông mạng & Top URL đi qua
# ==========================================================================

# Đường dẫn cấu hình tương thích với script trước
CONFIG_FILE="/etc/3proxy/3proxy.cfg"
LOG_FILE="/var/log/proxy_check.log"
PROXY_LOG="/var/log/3proxy.log" # Đảm bảo trong 3proxy.cfg có dòng log /var/log/3proxy.log nếu muốn xem URL

# Tự động tìm interface mạng chính
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')

# Hàm tính toán băng thông Up/Down thực tế của hệ thống
get_network_traffic() {
    local eth=$1
    # Đọc byte nhận/truyền trực tiếp từ nhân Linux Kernel
    local rx_before=$(cat /proc/net/dev | grep "$eth" | awk '{print $2}')
    local tx_before=$(cat /proc/net/dev | grep "$eth" | awk '{print $10}')
    sleep 1
    local rx_after=$(cat /proc/net/dev | grep "$eth" | awk '{print $2}')
    local tx_after=$(cat /proc/net/dev | grep "$eth" | awk '{print $10}')

    # Tính toán tốc độ KB/s
    RX_SPEED=$(( (rx_after - rx_before) / 1024 ))
    TX_SPEED=$(( (tx_after - tx_before) / 1024 ))
}

# Vòng lặp làm mới màn hình sau mỗi 2 giây (Giống lệnh top)
while true; do
    clear
    echo "=========================================================================="
    echo "            HỆ THỐNG GIÁM SÁT PROXY REAL-TIME (Tự động cập nhật)        "
    echo "=========================================================================="
    
    # 1. KIỂM TRA TRẠNG THÁI TIẾN TRÌNH
    if pgrep -x "3proxy" > /dev/null; then
        PROXY_STATUS="RUNNING (Ổn định)"
        PID=$(pgrep -x "3proxy" | head -n 1)
        # Lấy lượng RAM/CPU của riêng tiến trình 3proxy sử dụng
        PROXY_RES=$(ps -p $PID -o %cpu,%mem --no-headers 2>/dev/null)
    else
        PROXY_STATUS="STOPPED (Đã sập)"
        PROXY_RES="0.0  0.0"
    fi
    
    # 2. THỐNG KÊ SỐ LƯỢNG PORT & TÌNH TRẠNG LIVE/DIE
    if [ -f "$CONFIG_FILE" ]; then
        TOTAL_PORTS=$(grep -c "proxy -6" $CONFIG_FILE)
    else
        TOTAL_PORTS=0
    fi
    
    # Đếm số lượng port lỗi từ file log check gần nhất của script trước
    if [ -f "$LOG_FILE" ]; then
        DIE_PORTS=$(grep -c "DIE:" $LOG_FILE)
    else
        DIE_PORTS=0
    fi
    LIVE_PORTS=$((TOTAL_PORTS - DIE_PORTS))
    [ $LIVE_PORTS -lt 0 ] && LIVE_PORTS=0

    # 3. ĐO BĂNG THÔNG UP/DOWN THỰC TẾ
    get_network_traffic $INTERFACE

    # XUẤT THÔNG TIN RA BẢNG TỔNG QUAN
    echo -e " Trạng thái dịch vụ:  $PROXY_STATUS"
    echo -e " CPU/RAM sử dụng:     $PROXY_RES %"
    echo -e " Tổng số Port chạy:   $TOTAL_PORTS ports"
    echo -e " Tình trạng kết nối:  SỐNG: $LIVE_PORTS  |  CHẾT: $DIE_PORTS"
    echo "--------------------------------------------------------------------------"
    echo -e " BĂNG THÔNG MẠNG HỆ THỐNG (Tải luồng data Up/Down):"
    echo -e " ⬇️ Tốc độ Tải về (Download):  $RX_SPEED KB/s (~ $((RX_SPEED * 8 / 1024)) Mbps)"
    echo -e " ⬆️ Tốc độ Đẩy lên (Upload):    $TX_SPEED KB/s (~ $((TX_SPEED * 8 / 1024)) Mbps)"
    echo "=========================================================================="
    
    # 4. TRÍCH XUẤT CÁC URL / TÊN MIỀN ĐANG ĐI QUA PROXY NHIỀU NHẤT
    echo " TOP 10 CÁC URL/TÊN MIỀN ĐANG ĐƯỢC CÁC LUỒNG PROXY TRUY CẬP:"
    echo "--------------------------------------------------------------------------"
    if [ -f "$PROXY_LOG" ] && [ -s "$PROXY_LOG" ]; then
        # Đọc 500 dòng log cuối, trích xuất cột chứa tên miền/IP đích và đếm số lần xuất hiện
        tail -n 500 $PROXY_LOG | awk '{print $9}' | grep -E '([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})' | sort | uniq -c | sort -nr | head -n 10 | awk '{printf "  👉 Lượt truy cập: %-5s | Đích đến: %s\n", $1, $2}'
    else
        echo " (Chưa có dữ liệu luồng URL đi qua hoặc tính năng ghi log của 3proxy đang tắt)"
    fi
    echo "=========================================================================="
    echo " Nhấn [CTRL + C] để thoát màn hình theo dõi."
    
    sleep 1
done

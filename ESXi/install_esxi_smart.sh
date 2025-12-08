#!/bin/sh
#
# ESXi SMART monitoring installer/updater (без SSH на Zabbix)
# Запускать от root на ESXi:  /bin/sh install_esxi_smart.sh
#

# ===== НАСТРОЙКИ =====
ZBX_IP="<ZABBIX_IP>"        # IP сервера с Zabbix/rsyslog
ZBX_PORT="514"                # порт syslog
MAX_LEN="2048"                # максимальная длина удалённого сообщения
CRON_EXPR="*/5 * * * * /opt/scripts/smart-logger.sh"

RUNTIME_SCRIPT="/opt/scripts/smart-logger.sh"
PERSIST_SCRIPT="/store/scripts/smart-logger.sh"
CRON_FILE="/var/spool/cron/crontabs/root"
RC_LOCAL="/etc/rc.local.d/local.sh"
RC_MARK_BEGIN="# --- Restore SMART logger after reboot ---"
RC_MARK_END="# --- End of SMART logger restore ---"

echo "=== ESXi SMART installer ==="

# ----- 1. Хостнейм (по желанию) -----
echo
echo -n "Введите hostname для ESXi (пусто — не менять): "
read NEW_HOST

if [ -n "$NEW_HOST" ]; then
    echo "[*] Меняю hostname на: $NEW_HOST"
    esxcli system hostname set --host="$NEW_HOST" 2>/dev/null || \
        echo "[!] Не удалось задать hostname (проверь права/формат)"
else
    echo "[*] Hostname оставляем как есть"
fi

echo
echo "[*] Текущий hostname:"
esxcli system hostname get 2>/dev/null || true

# ----- 2. Syslog -> Zabbix (TCP + max len) -----
echo
echo "[*] Настраиваю syslog на tcp://${ZBX_IP}:${ZBX_PORT} c max len ${MAX_LEN}..."

esxcli system syslog config set --loghost="tcp://${ZBX_IP}:${ZBX_PORT}" || \
    echo "[!] Не удалось задать loghost"

esxcli system syslog config set --remote-host-max-msg-len="${MAX_LEN}" || \
    echo "[!] Не удалось задать remote-host-max-msg-len"

# Разрешаем syslog в firewall
esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true 2>/dev/null || \
    echo "[!] Не удалось включить ruleset syslog (возможно, уже включен)"

# Перечитать конфиг syslog
esxcli system syslog reload || echo "[!] esxcli system syslog reload: ошибка (проверь логи)"

echo
echo "[*] Текущая конфигурация syslog:"
esxcli system syslog config get || true

# ----- 3. Установка/обновление smart-logger.sh -----
echo
echo "[*] Готовлю каталоги для скрипта..."
mkdir -p /opt/scripts /store/scripts

# Пытаемся взять smart-logger.sh из того же каталога, где лежит инсталлер
SCRIPT_DIR="$(dirname "$0")"
SRC_SCRIPT="${SCRIPT_DIR}/smart-logger.sh"

if [ -f "$SRC_SCRIPT" ]; then
    echo "[*] Нашёл smart-logger.sh рядом с инсталлером, обновляю..."
    cp "$SRC_SCRIPT" "$PERSIST_SCRIPT" || echo "[!] Не удалось скопировать в $PERSIST_SCRIPT"
    cp "$SRC_SCRIPT" "$RUNTIME_SCRIPT" || echo "[!] Не удалось скопировать в $RUNTIME_SCRIPT"
elif [ -f "$PERSIST_SCRIPT" ]; then
    echo "[*] Нового smart-logger.sh рядом нет, используем уже сохранённый в $PERSIST_SCRIPT"
    cp "$PERSIST_SCRIPT" "$RUNTIME_SCRIPT" || echo "[!] Не удалось скопировать в $RUNTIME_SCRIPT"
else
    echo "[!] ВНИМАНИЕ: smart-logger.sh не найден ни рядом, ни в $PERSIST_SCRIPT"
    echo "    Положи актуальный smart-logger.sh рядом с install_esxi_smart.sh и запусти ещё раз."
fi

if [ -f "$RUNTIME_SCRIPT" ]; then
    chmod +x "$RUNTIME_SCRIPT" "$PERSIST_SCRIPT" 2>/dev/null || true
    echo "[*] Скрипт SMART-логгера установлен в $RUNTIME_SCRIPT и $PERSIST_SCRIPT"
fi

# ----- 4. Cron -----
echo
echo "[*] Настраиваю cron для smart-logger.sh..."
mkdir -p "$(dirname "$CRON_FILE")"

if [ ! -f "$CRON_FILE" ]; then
    touch "$CRON_FILE"
fi

if grep -q "smart-logger.sh" "$CRON_FILE" 2>/dev/null; then
    echo "[*] Запись для smart-logger.sh уже есть в cron, не добавляю дубликат."
else
    echo "$CRON_EXPR" >> "$CRON_FILE"
    echo "[*] Добавлена строка в cron: $CRON_EXPR"
fi

echo "[*] Перезапускаю cron..."

# мягкий вариант
if [ -f /var/run/crond.pid ]; then
    kill "$(cat /var/run/crond.pid)" 2>/dev/null
fi

# запуск нового
crond 2>/dev/null || /usr/lib/vmware/busybox/bin/busybox crond

echo "[*] Cron перезапущен."

# ----- 5. rc.local.d/local.sh (восстановление после ребута) -----
echo
echo "[*] Настраиваю восстановление скрипта и cron через $RC_LOCAL..."

if [ ! -f "$RC_LOCAL" ]; then
    echo "[*] Файл $RC_LOCAL не найден, создаю базовый..."
    mkdir -p "$(dirname "$RC_LOCAL")"
    {
        echo "#!/bin/sh"
        echo "exit 0"
    } > "$RC_LOCAL"
    chmod +x "$RC_LOCAL"
fi

# Если наш блок уже есть — не добавляем второй раз
if grep -q "$RC_MARK_BEGIN" "$RC_LOCAL" 2>/dev/null; then
    echo "[*] Блок ESXI_SMART_NO_SSH уже есть в $RC_LOCAL, не трогаю."
else
    echo "[*] Добавляю блок ESXI_SMART_NO_SSH в $RC_LOCAL..."
    TMP_RC="/tmp/rc.local.$$"

    # Вставляем блок перед последним 'exit 0'
    awk -v begin="$RC_MARK_BEGIN" -v end="$RC_MARK_END" '
        /exit 0/ && !done {
            print begin
            print "if [ -f /store/scripts/smart-logger.sh ]; then"
            print "    logger -t SMART_RESTORE \"Restoring smart-logger.sh and cron\""
            print "    mkdir -p /opt/scripts"
            print "    cp /store/scripts/smart-logger.sh /opt/scripts/"
            print "    chmod +x /opt/scripts/smart-logger.sh"
            print ""
            print "    if ! grep -q \"smart-logger.sh\" /var/spool/cron/crontabs/root 2>/dev/null; then"
            print "        echo \"*/5 * * * * /opt/scripts/smart-logger.sh\" >> /var/spool/cron/crontabs/root"
            print "    fi"
            print "    logger -t SMART_RESTORE \"Restore complete\""
            print "fi"
            print end
            print ""
            done=1
        }
        { print }
    ' "$RC_LOCAL" > "$TMP_RC" && mv "$TMP_RC" "$RC_LOCAL"

    chmod +x "$RC_LOCAL"
fi

# ----- 6. Сохранение конфигурации ESXi -----
echo
echo "[*] Запускаю /sbin/auto-backup.sh для сохранения конфигурации..."
/sbin/auto-backup.sh || echo "[!] auto-backup.sh вернул ошибку, проверь логи ESXi."

echo
echo "=== Готово. Проверка: ==="
echo "1) SMART-логгер: $RUNTIME_SCRIPT"
echo "2) Cron-файл: $CRON_FILE"
echo "3) rc.local:   $RC_LOCAL"
echo "4) Syslog на Zabbix: tcp://${ZBX_IP}:${ZBX_PORT}, max len ${MAX_LEN}"
echo "Можно руками запустить:  /opt/scripts/smart-logger.sh"

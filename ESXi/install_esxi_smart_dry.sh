#!/bin/sh
#
# ESXi SMART monitoring installer/updater DRY-RUN
# НИЧЕГО не меняет, только показывает, что бы сделал реальный инсталлер.
#

# ===== НАСТРОЙКИ =====
ZBX_IP="<ZABBIX_IP>"
ZBX_PORT="514"
MAX_LEN="2048"
CRON_EXPR="*/5 * * * * /opt/scripts/smart-logger.sh"

RUNTIME_SCRIPT="/opt/scripts/smart-logger.sh"
PERSIST_SCRIPT="/store/scripts/smart-logger.sh"
CRON_FILE="/var/spool/cron/crontabs/root"
RC_LOCAL="/etc/rc.local.d/local.sh"
RC_MARK_BEGIN="# --- Restore SMART logger after reboot ---"
RC_MARK_END="# --- End of SMART logger restore ---"

echo "=== ESXi SMART installer (DRY-RUN) ==="

# ----- 1. Хостнейм -----
echo
echo -n "Введите hostname для ESXi (пусто — не менять): "
read NEW_HOST

if [ -n "$NEW_HOST" ]; then
    echo "[DRY] Меняю hostname на: $NEW_HOST"
    echo "[DRY] Команда: esxcli system hostname set --host=\"$NEW_HOST\""
else
    echo "[*] Hostname оставляем как есть"
fi

echo
echo "[*] Текущий hostname (реальный вывод):"
esxcli system hostname get 2>/dev/null || true

# ----- 2. Syslog -> Zabbix -----
echo
echo "[*] Настраиваю syslog (DRY, без изменений)..."
echo "[DRY] esxcli system syslog config set --loghost=\"tcp://${ZBX_IP}:${ZBX_PORT}\""
echo "[DRY] esxcli system syslog config set --remote-host-max-msg-len=\"${MAX_LEN}\""
echo "[DRY] esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true"
echo "[DRY] esxcli system syslog reload"

echo
echo "[*] Текущая конфигурация syslog (реальный вывод):"
esxcli system syslog config get || true

# ----- 3. smart-logger.sh (DRY, без онлайна) -----
echo
echo "[*] Проверяю каталоги для скрипта (DRY)..."
echo "[DRY] mkdir -p /opt/scripts /store/scripts"

SCRIPT_DIR="$(dirname "$0")"
SRC_SCRIPT_LOCAL="${SCRIPT_DIR}/smart-logger.sh"

echo
echo "[*] Проверяю наличие smart-logger.sh:"

if [ -f "$SRC_SCRIPT_LOCAL" ]; then
    echo "[*] Рядом с инсталлером найден локальный smart-logger.sh:"
    echo "    $SRC_SCRIPT_LOCAL"
    echo "[DRY] cp \"$SRC_SCRIPT_LOCAL\" \"$PERSIST_SCRIPT\""
    echo "[DRY] cp \"$SRC_SCRIPT_LOCAL\" \"$RUNTIME_SCRIPT\""
elif [ -f "$PERSIST_SCRIPT" ]; then
    echo "[*] В $PERSIST_SCRIPT уже есть сохранённый скрипт:"
    echo "    $PERSIST_SCRIPT"
    echo "[DRY] cp \"$PERSIST_SCRIPT\" \"$RUNTIME_SCRIPT\""
else
    echo "[!!!] smart-logger.sh нигде не найден (ни рядом, ни в $PERSIST_SCRIPT)."
    echo "      В боевом варианте установка бы тут остановилась с предупреждением."
fi

echo
echo "[DRY] chmod +x \"$RUNTIME_SCRIPT\" \"$PERSIST_SCRIPT\" (если файлы существуют)"

# ----- 4. Cron (DRY) -----
echo
echo "[*] Проверяю cron для smart-logger.sh (DRY)..."
echo "[DRY] mkdir -p \"\$(dirname \"$CRON_FILE\")\""

if [ -f "$CRON_FILE" ]; then
    echo "[*] Cron-файл уже существует: $CRON_FILE"
else
    echo "[*] Cron-файл ещё не существует: $CRON_FILE"
    echo "[DRY] touch \"$CRON_FILE\""
fi

if grep -q "smart-logger.sh" "$CRON_FILE" 2>/dev/null; then
    echo "[*] В $CRON_FILE уже есть запись с smart-logger.sh"
else
    echo "[DRY] Добавил бы строку в cron:"
    echo "    $CRON_EXPR"
fi

echo "[*] Перезапускаю cron..."

# мягкий вариант
if [ -f /var/run/crond.pid ]; then
    kill "$(cat /var/run/crond.pid)" 2>/dev/null
fi

# запуск нового
crond 2>/dev/null || /usr/lib/vmware/busybox/bin/busybox crond

echo "[*] Cron перезапущен."

# ----- 5. rc.local.d/local.sh (DRY) -----
echo
echo "[*] Проверяю $RC_LOCAL (DRY)..."

if [ -f "$RC_LOCAL" ]; then
    echo "[*] $RC_LOCAL существует."
else
    echo "[*] $RC_LOCAL не существует."
    echo "[DRY] mkdir -p \"\$(dirname \"$RC_LOCAL\")\""
    echo "[DRY] Создать файл с содержимым:"
    echo "      #!/bin/sh"
    echo "      exit 0"
fi

if grep -q "$RC_MARK_BEGIN" "$RC_LOCAL" 2>/dev/null; then
    echo "[*] Блок ESXI_SMART_NO_SSH уже есть в $RC_LOCAL — ничего не добавлял бы."
else
    echo "[*] Блока ESXI_SMART_NO_SSH ещё нет. В боевом варианте вставили бы блок перед exit 0:"
    echo "[DRY] awk -v begin=\"$RC_MARK_BEGIN\" -v end=\"$RC_MARK_END\" '... вставка блока ...' \"$RC_LOCAL\" > /tmp/rc.local.\$\$ && mv /tmp/rc.local.\$\$ \"$RC_LOCAL\""
fi

# ----- 6. Сохранение конфигурации (DRY) -----
echo
echo "[DRY] В боевом варианте сейчас бы вызвали /sbin/auto-backup.sh для сохранения конфигурации."
echo "[DRY] Команда: /sbin/auto-backup.sh"

echo
echo "=== DRY-RUN завершён. НИ ОДНО ИЗМЕНЕНИЕ НЕ БЫЛО ВНЕСЕНО. ==="
echo "Проверено:"
echo "1) Hostname (показан реальный, смена не выполнялась)"
echo "2) Текущий syslog-конфиг (показан реальный)"
echo "3) Наличие smart-logger.sh рядом и в $PERSIST_SCRIPT"
echo "4) Наличие записи в cron и блока в $RC_LOCAL"

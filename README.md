# 📘 Мониторинг SMART-дисков ESXi в Zabbix

> 🇬🇧 [English version available → README_EN.md](./README_EN.md)

## Описание

Проект предназначен для мониторинга состояния **отдельных физических дисков** на ESXi-хостах (не в RAID) с отправкой данных в Zabbix.  
Решение не требует установки сторонних пакетов на ESXi и постоянного SSH-доступа.  
Для сбора информации используются только встроенные средства ESXi (`esxcli`, syslog, cron).

Общий принцип работы:  
- на ESXi SMART-метрики пишутся в системный лог,  
- логи пересылаются на сервер с Zabbix через syslog,  
- на сервере их обрабатывает форвардер и передаёт в Zabbix через `zabbix_sender`.  

---

## Ограничения ⚠️
- Если хост добавлен в vCenter и изменить его hostname — он отвалится от vCenter.  
- Имя хоста на ESXi должно совпадать с именем узла в Zabbix.  
- Работа с RAID-контроллерами и массивами не тестировалась. 

---

## Tested Environment

- Ubuntu Server 24.04.2 LTS (kernel 6.8)  
- Zabbix Server 7.4.0  
- zabbix_agentd 7.4.2 (в комплекте есть zabbix_sender)  
- rsyslog и logrotate — стандартные из Ubuntu 24.04  
- VMware ESXi: от 6.5 до 8.0e   

---

## Схема работы

1. **ESXi** — скрипт `smart-logger.sh` раз в 5 минут пишет SMART-данные в `syslog.log`:  
   - `SMART_DISCOVERY` — JSON для LLD в Zabbix,  
   - `SMART_DATA` / `SMART_STATS` — метрики по каждому диску.  

2. **Ubuntu (сервер с Zabbix)** — rsyslog принимает логи и сохраняет их в:  
   ```
   /var/log/esxi/<hostname>/system.log
   ```
   Используется имя хоста (а не IP), чтобы избежать проблем с NAT.  
   ⚠️ В конфиге rsyslog предусмотрено исключение логов самого сервера — замените `<ZABBIX_SERVER_IP>` на адрес вашей системы.  

3. **Форвардер (forwarder.sh)**:  
   - следит за логами (`tail -F`),  
   - разбирает строки и сохраняет их во временные файлы (`*.metrics`, `*.discovery`),  
   - каждые 30 секунд отправляет данные в Zabbix через `zabbix_sender`,  
   - очищает временные файлы после передачи.  

4. **Zabbix** — шаблон `Template ESXi SMART`:  
   - автоматически обнаруживает диски,  
   - собирает метрики,  
   - содержит триггеры на ошибки, состояние и температуру.  

Схема:  
```
ESXi → syslog → rsyslog (Ubuntu) → forwarder.sh → zabbix_sender → Zabbix Template
```

---

## Быстрый старт

### На ESXi

## Автоматическая установка и обновление SMART-мониторинга на ESXi

Подробная инструкция по использованию автоустановщика:

➡ [ESXi/INSTALL_AUTOMATION.md](ESXi/INSTALL_AUTOMATION.md)

## Либо руками

```bash
# Проверить/задать имя хоста
esxcli system hostname get
esxcli system hostname set --host=hostname

# Включить пересылку логов на Zabbix-сервер
esxcli system syslog config set --loghost='udp://<ZABBIX_IP>:514'
esxcli system syslog reload

# Firewall Разрешить пересылку логов
esxcli network firewall ruleset set --ruleset-id=syslog --enabled=true

# Установить скрипт SMART-логгера
mkdir -p /opt/scripts/
vi /opt/scripts/smart-logger.sh
chmod +x /opt/scripts/smart-logger.sh

# Добавить в cron
vi /var/spool/cron/crontabs/root
*/5 * * * * /opt/scripts/smart-logger.sh
```

После этого можно проверить запустив скрипт руками
```bash
/opt/scripts/smart-logger.sh
```
## Важно для ESXi

Файловые пути /opt, /var, /tmp и crontab на ESXi находятся в RAM и очищаются после каждой перезагрузки.  
Чтобы скрипт и расписание не терялись:

1. Скопируйте smart-logger.sh в постоянное хранилище:
   mkdir -p /store/scripts
   cp /opt/scripts/smart-logger.sh /store/scripts/
   chmod +x /store/scripts/smart-logger.sh

2. Восстанавливайте скрипт и cron при загрузке через /etc/rc.local.d/local.sh (добавьте перед exit 0):

   ```bash
   # --- Restore SMART logger after reboot ---
   if [ -f /store/scripts/smart-logger.sh ]; then
       logger -t SMART_RESTORE "Restoring smart-logger.sh and cron"
       mkdir -p /opt/scripts
       cp /store/scripts/smart-logger.sh /opt/scripts/
       chmod +x /opt/scripts/smart-logger.sh

       if ! grep -q "smart-logger.sh" /var/spool/cron/crontabs/root 2>/dev/null; then
           echo "*/5 * * * * /opt/scripts/smart-logger.sh" >> /var/spool/cron/crontabs/root
       fi

       logger -t SMART_RESTORE "Restore complete"
   fi
   # --- End restore ---
   ```
   ```bash
   chmod +x /etc/rc.local.d/local.sh
   ```

Теперь при каждом запуске хост восстановит скрипт и cron-задачу автоматически.

3. Сохранение конфигурации
   ```bash
   /sbin/auto-backup.sh
   ```

### На Ubuntu
```bash
# Каталоги для логов ESXi
sudo mkdir -p /var/log/esxi
sudo chown syslog:adm /var/log/esxi

# Добавить конфиг rsyslog (см. ./etc/rsyslog.d/40-esxi.conf)
# Не забыть заменить <ZABBIX_SERVER_IP> в конфиге!

sudo systemctl restart rsyslog

# Добавить конфиг logrotate (см. ./etc/logrotate.d/esxi-logs)

# Установить forwarder.sh
sudo mkdir -p /opt/scripts/
sudo cp forwarder.sh /opt/scripts/
sudo chmod +x /opt/scripts/forwarder.sh

# установить systemd unit
sudo cp zbx-forwarder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zbx-forwarder.service
```

### В Zabbix
1. Импортировать шаблон `Template ESXi SMART.xml`.  
2. Привязать к хостам ESXi.  
3. Проверить появление метрик SMART.  


👉 Минимальный набор команд и конфигураций приведён в [INSTALL.md](INSTALL.md).  
Там же указаны проверки и примеры ожидаемых результатов. 

---

## Проверка работы

- Логи появляются: `/var/log/esxi/<hostname>/system.log`.  
- Форвардер пишет служебный лог: `/var/log/esxi/esxi_smart_forwarder.log`.  
- В Zabbix видны SMART-метрики по дискам и работают триггеры.  

---

## Структура репозитория

- `Zabbix(Ubuntu)/etc/rsyslog.d/40-esxi.conf` — конфиг rsyslog  
- `Zabbix(Ubuntu)/etc/logrotate.d/esxi-logs` — конфиг logrotate  
- `Zabbix(Ubuntu)/opt/scripts/forwarder.sh` — форвардер на Ubuntu  
- `Zabbix(Ubuntu)/etc/systemd/system/zbx-forwarder.service` — systemd unit
- `ESXi/opt/scripts/smart-logger.sh` — скрипт для запуска на ESXi
- `zabbix_templates/Template_ESXi_SMART.xml` — шаблон для Zabbix
- `README.md` — эта инструкция
- `INSTALL.md` — пошаговая установка с примерами

---

## !!!

Проект собран для внутреннего использования, но может быть полезен любому, кто хочет **мониторить диски ESXi без сторонних агентов и постоянного SSH**.  

---

## Лицензия

MIT License.  
# Подробная установка (Step-by-step)

Здесь описан полный процесс с пояснениями — зачем именно выполняются шаги и что проверять.

---

## 1. Настройка ESXi

### 1.1. Проверка и установка hostname
Имя хоста в ESXi должно совпадать с именем узла в Zabbix.  
Если этого не сделать — данные просто не попадут в нужный хост.

```bash
esxcli system hostname get
```
Ожидаемый результат:  
```
   Hostname: esxi-01.st.local
```
(имя должно совпадать с именем узла в Zabbix).

Чтобы задать новое:  
```bash
esxcli system hostname set --host=hostname
```

---

### 1.2. Пересылка логов
Включаем syslog, чтобы логи летели на сервер с Zabbix.

```bash
esxcli system syslog config set --loghost='udp://<ZABBIX_IP>:514'
esxcli system syslog reload
esxcli system syslog config get
```
Ожидаемый результат:  
```
   LogHost: udp://<ZABBIX_IP>:514
```
Если пусто — значит команда не сработала.

---

### 1.3. Скрипт SMART-логгера
Скрипт раз в 5 минут пишет SMART в syslog.

```bash
mkdir -p /opt/scripts/
vi /opt/scripts/smart-logger.sh
chmod +x /opt/scripts/smart-logger.sh

vi /var/spool/cron/crontabs/root
*/5 * * * * /opt/scripts/smart-logger.sh
```

Проверка:  
```bash
/opt/scripts/smart-logger.sh
tail -n 20 /var/log/syslog.log
```
Ожидаемый результат: среди кучи обычных сообщений (`sshd`, `kernel`) должны появляться строки: 
```
SMART_DATA[...] esxi.smart.health_status[...] OK
SMART_DISCOVERY { "data": [...] }
```

### Устойчивость после перезагрузки

ESXi очищает /opt, /var и cron при ребуте, поэтому smart-logger.sh нужно восстанавливать.

1. Сохраните скрипт в постоянное хранилище /store:
   mkdir -p /store/scripts
   cp /opt/scripts/smart-logger.sh /store/scripts/
   chmod +x /store/scripts/smart-logger.sh

2. Добавьте восстановление в /etc/rc.local.d/local.sh (перед строкой exit 0):

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

После перезагрузки проверь:
   ```bash
   grep SMART_RESTORE /var/log/syslog.log | tail -n 5
   cat /var/spool/cron/crontabs/root | grep smart-logger
   ls -l /opt/scripts/smart-logger.sh
   ```

---

## 2. Настройка Ubuntu (Zabbix-сервера)

### 2.1. Каталоги для логов
Создаём каталог, даём права syslog:adm.

```bash
sudo mkdir -p /var/log/esxi
sudo chown syslog:adm /var/log/esxi
```

---

### 2.2. Rsyslog
Файл `40-esxi.conf` настраивает:  
- принимает UDP/514,  
- складывает в `/var/log/esxi/<hostname>/system.log`,  
- создаёт папки сам.  

```bash
sudo cp etc/rsyslog.d/40-esxi.conf /etc/rsyslog.d/
sudo systemctl restart rsyslog
```
⚠️ В конфиге замените `<ZABBIX_SERVER_IP>` на адрес вашего сервера, чтобы исключить его собственные логи.

Проверка:  
```bash
ls -l /var/log/esxi/
```
Ожидаемый результат: папки с именами ESXi. 

```bash
tail -n 20 /var/log/esxi/<hostname>/system.log
```
Ожидаемый результат: видны строки SMART_DATA или SMART_DISCOVERY.

---

### 2.3. Logrotate
Чтобы логи не сожрали диск.

```bash
sudo cp etc/logrotate.d/esxi-logs /etc/logrotate.d/
sudo logrotate -f /etc/logrotate.d/esxi-logs
```
Ожидаемый результат: рядом с `system.log` появились файлы `system.log.1`, `system.log.2.gz` и т.п.

---

### 2.4. Forwarder
Форвардер следит за логами, собирает данные во временные файлы и пачками шлёт в Zabbix.

```bash
sudo mkdir -p /opt/scripts/
sudo cp opt/scripts/forwarder.sh /opt/scripts/
sudo chmod +x /opt/scripts/forwarder.sh
```

---

### 2.5. Systemd-сервис
Чтобы форвардер запускался сам и перезапускался при падении.

```bash
sudo cp etc/systemd/system/zbx-forwarder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zbx-forwarder.service
```

Проверка:
```bash
systemctl status zbx-forwarder.service
```
Ожидаемый результат:  `active (running)`.  

```bash
journalctl -u zbx-forwarder.service -f
```
Ожидаемый результат: строки типа таких 
```
METRIC -> host=esxi-01.st.local esxi.smart.temperature[...] 34
DISCOVERY -> host=esxi-01.st.local
```

---

## 3. Zabbix

1. Импортируйте `Template ESXi SMART.xml`.  
2. Привяжите к хостам.  
3. Метрики появятся автоматически.  

---

## Проверка

- Логи есть: `/var/log/esxi/<hostname>/system.log` и его ротации.  
- Форвардер пишет в `/var/log/esxi/esxi_smart_forwarder.log`.  
- В Zabbix видны метрики и срабатывают триггеры.

---

## Итог

```
ESXi → syslog → rsyslog (Ubuntu) → forwarder.sh → zabbix_sender → Zabbix Template
```

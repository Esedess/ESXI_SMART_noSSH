# ESXi SMART Disk Monitoring (no SSH, no agents)

This project provides SMART disk monitoring for standalone **VMware ESXi hosts** in **Zabbix**,  
without SSH access, without installing any additional software on hosts,  
and without vCenter dependencies.

---

## 💡 What It Does

- Collects **SMART data** directly on ESXi using native `esxcli` commands  
- Sends results to a central Ubuntu server via **syslog**  
- Parses logs with a lightweight **forwarder script** and pushes metrics to **Zabbix**  
- Supports **Low-Level Discovery (LLD)** — new disks appear automatically  

**Data flow:**
```
ESXi → syslog → rsyslog (Ubuntu) → forwarder.sh → zabbix_sender → Zabbix Template
```

---

## 🧱 Features

- Works even on **standalone ESXi hosts** (no vCenter required)  
- **No persistent SSH** connection needed  
- **No third-party packages** on the hypervisor  
- **Auto-discovery** of disks and metrics  
- **Simple shell scripts**, no daemons or binaries  

---

## ⚙️ Tested Environment

| Component | Version |
|------------|----------|
| **Ubuntu Server** | 24.04.2 LTS |
| **Zabbix Server** | 7.4.0 |
| **ESXi Hosts** | 6.5 → 8.0e |
| **Rsyslog / logrotate** | Default Ubuntu packages |

---

## 🚀 Quick Start

1. Configure syslog forwarding on ESXi:  
   ```bash
   esxcli system syslog config set --loghost='udp://<ZABBIX_IP>:514'
   esxcli system syslog reload
   ```

2. Copy `smart-logger.sh` to `/opt/scripts/` on the ESXi host and add it to cron:  
   ```bash
   */5 * * * * /opt/scripts/smart-logger.sh
   ```
   ## Important for ESXi

    File paths /opt, /var, /tmp, and crontab on ESXi reside in RAM and are cleared after every reboot.
    To make the script and schedule persistent:

    1. Copy smart-logger.sh to a persistent storage (for example, /store):
      mkdir -p /store/scripts
      cp /opt/scripts/smart-logger.sh /store/scripts/
      chmod +x /store/scripts/smart-logger.sh

    2. Restore the script and cron job automatically at boot via /etc/rc.local.d/local.sh
      (add this block before exit 0):

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
      Then make local.sh executable:
      ```bash
      chmod +x /etc/rc.local.d/local.sh
      ```

    After that, each time the host boots, it will automatically restore both the script and its cron job.

3. On the Zabbix server (Ubuntu):  
   - Place `40-esxi.conf` in `/etc/rsyslog.d/`  
   - ⚠️ Remember to replace `<ZABBIX_SERVER_IP>` in the rsyslog config with your actual server address.
   - Place `esxi-logs` in `/etc/logrotate.d/`  
   - Copy `forwarder.sh` to `/opt/scripts/`  
   - Enable the service:  
     ```bash
     sudo cp zbx-forwarder.service /etc/systemd/system/
     sudo systemctl enable --now zbx-forwarder.service
     ```

4. Import `Template ESXi SMART.xml` into Zabbix and link it to your ESXi hosts.

---

## 🔍 How It Works

- `smart-logger.sh` runs locally on ESXi every 5 minutes via cron  
  and writes SMART metrics to the local system log (`syslog.log`)  

- `rsyslog` on Ubuntu receives logs from all hosts and saves them to:  
  `/var/log/esxi/<hostname>/system.log`

- `forwarder.sh` tails these logs and sends metrics in batches to Zabbix via `zabbix_sender`  

- Temporary metric files are stored under `/var/log/esxi/tmp/`  
  and automatically cleaned after sending.

---

## ⚠️ Known Limitations

- Hostname **must match** between ESXi and Zabbix (used in metrics and folders)  
- Works best with **standalone hosts** — renaming a vCenter-managed host may detach it  
- RAID controllers are not tested  

---

## 🧩 Repository Structure

```
ESXi/opt/scripts/smart-logger.sh          # ESXi-side script
Zabbix (Ubuntu)/opt/scripts/forwarder.sh  # Log forwarder
Zabbix (Ubuntu)/etc/rsyslog.d/40-esxi.conf
Zabbix (Ubuntu)/etc/logrotate.d/esxi-logs
Zabbix (Ubuntu)/etc/systemd/system/zbx-forwarder.service
zabbix_templates/Template_ESXi_SMART.xml  # Zabbix template
README.md                                 # Russian main readme
INSTALL.md                                # Detailed Russian setup guide
README_EN.md                              # This file
```

---

## 🧠 Additional Notes

- All logic is pure **bash**, no Python, no compiled binaries  
- Scripts survive ESXi updates if placed in `/opt/` and reloaded via `local.sh`  
- Metrics like `esxi.smart.media_wearout` or `esxi.smart.health_status`  
  will trigger alerts when disk degradation is detected  

---

## 🪪 License

MIT License — © 2025 Nikita Troshkin

---

🇷🇺 **Русская версия:** [README.md](./README.md)  
🇷🇺 **Подробная установка:** [INSTALL.md](./INSTALL.md)

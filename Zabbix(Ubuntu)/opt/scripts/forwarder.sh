#!/bin/bash
#

set -u

LOGDIR="/var/log/esxi"
TMPDIR="$LOGDIR/tmp"
FORWARDER_LOG="$LOGDIR/esxi_smart_forwarder.log"

ZBX_SERVER="127.0.0.1"
ZBX_PORT="10051"

mkdir -p "$TMPDIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "$(ts) Forwarder started" >> "$FORWARDER_LOG"

process_line() {
    local logfile="$1"
    local line="$2"

    local host=$(basename "$(dirname "$logfile")")
    local tag=$(echo "$line" | awk '{print $3}' | cut -d'[' -f1)

    case "$tag" in
      SMART_DISCOVERY)
        JSON="$(echo "$line" | sed 's/^[^{]*//')"
        echo "\"$host\" esxi.smart.discovery $JSON" >> "$TMPDIR/$host.discovery"
        echo "$(ts) DISCOVERY -> host=$host" >> "$FORWARDER_LOG"
        ;;
      SMART_DATA|SMART_STATS)
        # METRIC="$(echo "$line" | sed -n 's/.*\(esxi\.[^ ]* [^ ]*\)$/\1/p')"
        METRIC="$(echo "$line" | sed -n 's/.*\(esxi\.[^ ]* .*\)$/\1/p' | sed 's/[[:space:]]*$//')"
        if [[ -n "$METRIC" ]]; then
            echo "\"$host\" $METRIC" >> "$TMPDIR/$host.metrics"
            echo "$(ts) METRIC -> host=$host $METRIC" >> "$FORWARDER_LOG"
        fi
        ;;
    esac
}

# следим за всеми system.log, перескан каждые 30 секунд
while true; do
    for logfile in $(find "$LOGDIR" -mindepth 2 -maxdepth 2 -type f -name "system.log"); do
        # проверяем, что tail для этого файла ещё не запущен
        pgrep -f "tail -F $logfile" >/dev/null || {
            echo "$(ts) Start tail for $logfile" >> "$FORWARDER_LOG"
            tail -F "$logfile" | while read line; do
                process_line "$logfile" "$line"
            done &
        }
    done
    sleep 30
done &

# каждые 30 секунд слать накопленные данные
while true; do
    sleep 30

    for f in "$TMPDIR"/*.metrics "$TMPDIR"/*.discovery; do
        [ -f "$f" ] || continue
        [ -s "$f" ] || continue

        zabbix_sender -z "$ZBX_SERVER" -p "$ZBX_PORT" -i "$f" >> "$FORWARDER_LOG" 2>&1
        : > "$f"
    done
done

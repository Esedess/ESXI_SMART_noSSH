#!/bin/sh

ESXCLI="/bin/esxcli"

# 1) Список дисков
DEVICES=$($ESXCLI storage core device list | grep -E "^(naa|t10|nvme)" | awk '{print $1}')

# 2) LLD discovery
DISCOVERY_JSON=$(printf '{"data":[%s]}' "$(for d in $DEVICES; do printf '{"{#DISK}":"%s"},' "$d"; done | sed 's/,$//')")
logger -t SMART_DISCOVERY "$DISCOVERY_JSON"

# Вспомогалки парсинга SMART/STATS
smart_get() {
  echo "$SMART_DATA" | awk -v pat="$1" -v want="$2" '
    $0 ~ pat {
      line=$0
      gsub(/[ \t][ \t]+/, "\t", line)
      n=split(line, a, "\t")
      if (want=="value") print a[2]; else print a[n]
    }' 2>/dev/null
}

stat_get() {
  echo "$STATS_DATA" | awk -F': *' -v k="$1" '
    $1 ~ k { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' 2>/dev/null
}

# Функция выбора температуры
pick_temp() {
  value="$1"
  raw="$2"

  # Если оба отсутствуют
  [ "$value" = "N/A" ] && [ "$raw" = "N/A" ] && return

  # Особый случай Intel/псевдо-проценты: value=100 и raw=N/A → пропускаем
  if [ "$value" = "100" ] && { [ "$raw" = "N/A" ] || [ -z "$raw" ]; }; then
    return
  fi

  # Если raw отсутствует → берём value
  if [ "$raw" = "N/A" ] || [ -z "$raw" ]; then
    echo "$value"
    return
  fi

  # Если value отсутствует → берём raw
  if [ "$value" = "N/A" ] || [ -z "$value" ]; then
    echo "$raw"
    return
  fi

  # Оба есть → берём по логике: если raw < value, то raw, иначе value
  if [ "$raw" -lt "$value" ]; then
    echo "$raw"
  else
    echo "$value"
  fi
}

# 3) По каждому диску
for DEVICE in $DEVICES; do
  SMART_DATA=$($ESXCLI storage core device smart get -d "$DEVICE" 2>/dev/null)
  STATS_DATA=$($ESXCLI storage core device stats get -d "$DEVICE" 2>/dev/null)

  # SMART базовые
  HEALTH=$(smart_get "^Health Status" value)
  [ -n "$HEALTH" ] && logger -t SMART_DATA "esxi.smart.health_status[$DEVICE] $HEALTH"

  WEAR=$(smart_get "^Media Wearout Indicator" value)
  [ -n "$WEAR" ] && logger -t SMART_DATA "esxi.smart.media_wearout[$DEVICE] $WEAR"

  REALLOC_VAL=$(smart_get "^Reallocated Sector Count" value)
  [ -n "$REALLOC_VAL" ] && logger -t SMART_DATA "esxi.smart.reallocated_sectors[$DEVICE] $REALLOC_VAL"

  HOURS=$(smart_get "^Power-on Hours" raw)
  [ -n "$HOURS" ] && logger -t SMART_DATA "esxi.smart.power_on_hours[$DEVICE] $HOURS"

  # === ТЕМПЕРАТУРА ===
  TEMP_VALUE=$(smart_get "^Drive Temperature" value)
  TEMP_RAW=$(smart_get "^Drive Temperature" raw)
  TEMP_OK=$(pick_temp "$TEMP_VALUE" "$TEMP_RAW")
  if [ -n "$TEMP_OK" ]; then
    logger -t SMART_DATA "esxi.smart.temperature[$DEVICE] $TEMP_OK"
  fi

  # Остальные SMART
  UE=$(smart_get "^Uncorrectable Error Count" raw)
  [ -n "$UE" ] && logger -t SMART_DATA "esxi.smart.uncorrectable_errors[$DEVICE] $UE"

  US=$(smart_get "^Unsafe Shutdowns" raw)
  [ -n "$US" ] && logger -t SMART_DATA "esxi.smart.unsafe_shutdowns[$DEVICE] $US"

  ME=$(smart_get "^Media Errors" raw)
  [ -n "$ME" ] && logger -t SMART_DATA "esxi.smart.media_errors[$DEVICE] $ME"

  # STATS
  FC=$(stat_get "Failed Commands")
  [ -n "$FC" ] && logger -t SMART_STATS "esxi.stats.failed_commands[$DEVICE] $FC"

  FR=$(stat_get "Failed Read Operations")
  [ -n "$FR" ] && logger -t SMART_STATS "esxi.stats.failed_reads[$DEVICE] $FR"

  FW=$(stat_get "Failed Write Operations")
  [ -n "$FW" ] && logger -t SMART_STATS "esxi.stats.failed_writes[$DEVICE] $FW"

  RC=$(stat_get "Reservation Conflicts")
  [ -n "$RC" ] && logger -t SMART_STATS "esxi.stats.reservation_conflicts[$DEVICE] $RC"

  RO=$(stat_get "Read Operations")
  [ -n "$RO" ] && logger -t SMART_STATS "esxi.stats.read_ops[$DEVICE] $RO"

  WO=$(stat_get "Write Operations")
  [ -n "$WO" ] && logger -t SMART_STATS "esxi.stats.write_ops[$DEVICE] $WO"
done

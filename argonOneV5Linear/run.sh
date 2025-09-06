#!/usr/bin/with-contenv bashio
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

#################################
# 1. Utility functions
#################################

# Ensure a value is a float (adds “.0” if missing)
mkfloat() {
  local str="$1"
  [[ $str != *"."* ]] && str="${str}.0"
  echo "$str"
}

#################################
# 2. Detect I²C bus and address
#################################

calibrateI2CPort() {
  if [[ -z $(ls /dev/i2c-* 2>/dev/null) ]]; then
    echo "Cannot find any /dev/i2c-* device – enable I²C first."
    sleep 999999
    exit 1
  fi

  echo 'Detecting Layout of I²C, we expect to see "1a" here.'
  local thePort=""
  for device in /dev/i2c-*; do
    local port_scan=${device##*/i2c-}
    echo "checking i2c port ${port_scan} at ${device}"
    detection=$(i2cdetect -y "$port_scan")
    echo "$detection"
    if echo "$detection" | grep -q -E ' 1a | 1b '; then
      thePort=$port_scan
      echo "found at $device"
      break
    fi
    echo "not found on $device"
  done

  if [[ -z $thePort ]]; then
    echo "ArgonOne device not found on any I²C port"
    exit 1
  fi

  port=$thePort
  echo "I²C Port $port"
}

#################################
# 3. Pure-bash float comparison
#################################
# Usage: fcomp "1.23" -le "4.56"
fcomp() {
  local a="$1" op="$2" b="$3"

  # strip sign and keep sign separately
  local signA=1 signB=1
  [[ $a == -* ]] && signA=-1 a=${a#-}
  [[ $b == -* ]] && signB=-1 b=${b#-}
  a=${a#+}; b=${b#+}

  # split integer and fractional parts
  local ai="${a%%.*}" af="${a#*.}"
  local bi="${b%%.*}" bf="${b#*.}"
  [[ $a == "$ai" ]] && af=""
  [[ $b == "$bi" ]] && bf=""

  # pad fractional parts to same length without external tools
  while ((${#af} < ${#bf})); do af="${af}0"; done
  while ((${#bf} < ${#af})); do bf="${bf}0"; done

  # build comparable integers with sign
  local A="${ai}${af}"
  local B="${bi}${bf}"
  [[ -z $A ]] && A=0
  [[ -z $B ]] && B=0

  (( A = signA * A ))
  (( B = signB * B ))

  case "$op" in
    -lt) (( A <  B ));;
    -le) (( A <= B ));;
    -gt) (( A >  B ));;
    -ge) (( A >= B ));;
    -eq) (( A == B ));;
    -ne) (( A != B ));;
    *)   return 2;;
  esac
}

#################################
# 4. Push fan speed to HA sensor
#################################

fanSpeedReportLinear() {
  local fanPercent=$1 cpuTemp=$2 unit=$3
  local icon=mdi:fan
  local body
  body=$(jq -nc --arg s "$fanPercent" --arg t "$cpuTemp" --arg u "$unit" --arg icon "$icon" '{
    state: $s,
    attributes: {
      unit_of_measurement: "%",
      icon: $icon,
      ("Temperature "+$u): $t,
      friendly_name: "Argon Fan Speed"
    }
  }')
  exec 3<>/dev/tcp/hassio/80
  printf 'POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n' >&3
  printf 'Connection: close\r\nAuthorization: Bearer %s\r\n' "$SUPERVISOR_TOKEN" >&3
  printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3
  while read -t 5 -r _; do :; done <&3
  exec 3>&-
}

#################################
# 5. Write fan PWM with fallback
#################################

actionLinear() {
  local fanPercent=$1 cpuTemp=$2 unit=$3
  (( fanPercent < 0 ))  && fanPercent=0
  (( fanPercent > 100 ))&& fanPercent=100

  local fanHex
  printf -v fanHex '0x%02x' "$fanPercent"

  printf '%s: %s%s – Fan %s%% | hex:(%s)\n' \
    "$(date '+%Y-%m-%d_%H:%M:%S')" "$cpuTemp" "$unit" "$fanPercent" "$fanHex"

  if ! i2cset -y "$port" 0x1a "$fanHex" >/dev/null 2>&1; then
    i2cset -y "$port" 0x1b "$fanHex" >/dev/null 2>&1 || {
      echo "I²C write failed on both 0x1a and 0x1b – Safe-Mode."
      return 1
    }
  fi

  [[ $createEntity == true ]] && fanSpeedReportLinear "$fanPercent" "$cpuTemp" "$unit" &
}

#################################
# 6. Read add-on options
#################################

tmini=$(jq -r '."Minimum Temperature"'  /data/options.json 2>/dev/null || echo 55)
tmaxi=$(jq -r '."Maximum Temperature"'  /data/options.json 2>/dev/null || echo 85)
createEntity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo false)
tempUnit=$(jq -r '."Temperature Unit"'  /data/options.json 2>/dev/null || echo "F")

tmini=$(mkfloat "$tmini")
tmaxi=$(mkfloat "$tmaxi")

echo "Settings initialized. Argon One V5 Detected. Beginning monitor.."

#################################
# 7. Start
#################################

calibrateI2CPort

while true; do
  # Read CPU temperature
  cpuRaw=$(cat /sys/class/thermal/thermal_zone0/temp)
  cpuC=$(echo "scale=1; $cpuRaw/1000" | bc)

  if [[ $tempUnit == "C" ]]; then
    cpuTemp=$cpuC; unit="°C"
  else
    cpuTemp=$(echo "scale=1; $cpuC*9/5+32" | bc)
    unit="°F"
  fi

  echo "Current Temperature = $cpuTemp $unit"

  # Decide fan speed
  if fcomp "$cpuTemp" -le "$tmini"; then
    fan=0
  elif fcomp "$cpuTemp" -ge "$tmaxi"; then
    fan=100
  else
    range=$(echo "scale=2; $tmaxi - $tmini" | bc)
    diff=$(echo  "scale=2; $cpuTemp - $tmini" | bc)
    fan=$(echo  "scale=0;  $diff * 100 / $range" | bc)
  fi

  actionLinear "$fan" "$cpuTemp" "$unit"
  sleep 30
done

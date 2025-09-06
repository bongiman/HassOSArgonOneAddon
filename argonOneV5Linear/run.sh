#!/usr/bin/with-contenv bashio
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

##############################################################################
# 1  Utility functions
##############################################################################

# Append “.0” to bare integers so `bc` always sees a float
mkfloat() {
  local str="$1"
  [[ $str != *"."* ]] && str="${str}.0"
  echo "$str"
}

##############################################################################
# 2  Detect I²C bus and address
##############################################################################
calibrate_i2c_port() {
  if [[ -z $(ls /dev/i2c-* 2>/dev/null) ]]; then
    echo "Cannot find any /dev/i2c-* device – enable I²C first."
    exit 1
  fi

  echo 'Detecting layout of I²C, we expect to see "1a" or "1b".'
  local detected_port=""
  for device in /dev/i2c-*; do
    local bus=${device##*/i2c-}
    echo "checking i2c port ${bus} at ${device}"
    local scan; scan=$(i2cdetect -y "$bus")
    echo "$scan"
    if echo "$scan" | grep -q -E ' 1a | 1b '; then
      detected_port=$bus
      echo "found at $device"
      break
    fi
    echo "not found on $device"
  done

  [[ -z $detected_port ]] && {
    echo "ArgonOne device not found on any I²C port"; exit 1; }

  port=$detected_port
  echo "I²C Port $port"
}

##############################################################################
# 3  Simple float comparison –  fcomp  3.5  -ge  2.0
##############################################################################
fcomp() {
  local a="$1" op="$2" b="$3" sign_a=1 sign_b=1
  [[ $a == -* ]] && sign_a=-1 a=${a#-}
  [[ $b == -* ]] && sign_b=-1 b=${b#-}
  a=${a#+}; b=${b#+}
  local ai=${a%%.*} af=${a#*.} bi=${b%%.*} bf=${b#*.}
  [[ $a == "$ai" ]] && af=""; [[ $b == "$bi" ]] && bf=""
  while ((${#af} < ${#bf})); do af+=0; done
  while ((${#bf} < ${#af})); do bf+=0; done
  local A=$(( sign_a * 10#${ai}${af:-0} ))
  local B=$(( sign_b * 10#${bi}${bf:-0} ))
  case $op in
    -lt) (( A <  B ));;
    -le) (( A <= B ));;
    -gt) (( A >  B ));;
    -ge) (( A >= B ));;
    -eq) (( A == B ));;
    -ne) (( A != B ));;
  esac
}

##############################################################################
# 4  Push fan speed to Home Assistant
##############################################################################
fan_speed_report() {
  local pct=$1 t=$2 unit=$3
  local body; body=$(jq -nc --arg s "$pct" --arg t "$t" --arg u "$unit" '{
        state:$s,attributes:{unit_of_measurement:"%",("Temperature "+$u):$t,
        icon:"mdi:fan",friendly_name:"Argon Fan Speed"}}')

  exec 3<>/dev/tcp/hassio/80 || { echo "HA API unreachable"; return; }
  printf 'POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n' >&3
  printf 'Host: hassio\r\n' >&3                     # ← added header
  printf 'Authorization: Bearer %s\r\nConnection: close\r\n' "$SUPERVISOR_TOKEN" >&3
  printf 'Content-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3
  read -t 5 -r _ <&3 || echo "No reply from HA API"
  exec 3>&-
}

##############################################################################
# 5  Write fan PWM with fallback
##############################################################################
action_linear() {
  local pct=$1 temp=$2 unit=$3
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local hex; printf -v hex '0x%02x' "$pct"
  printf '%s: %s%s – Fan %s%% | hex:(%s)\n' "$(date '+%F_%T')" "$temp" "$unit" "$pct" "$hex"

  if ! i2cset -y "$port" 0x1a "$hex" >/dev/null 2>&1; then
       i2cset -y "$port" 0x1b "$hex" >/dev/null 2>&1 || {
         echo "I²C write failed on both 0x1a and 0x1b – Safe-Mode"; return 1; }
  fi

  [[ $create_entity == true ]] && fan_speed_report "$pct" "$temp" "$unit" &
}

##############################################################################
# 6  Load options
##############################################################################
tmini=$(mkfloat "$(jq -r '."Minimum Temperature"' /data/options.json 2>/dev/null || echo 55)")
tmaxi=$(mkfloat "$(jq -r '."Maximum Temperature"' /data/options.json 2>/dev/null || echo 85)")
create_entity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo false)
temp_unit=$(jq -r '."Temperature Unit"' /data/options.json 2>/dev/null || echo F)

echo "Settings initialized. Argon One V5 Detected. Beginning monitor.."

##############################################################################
# 7  Start main loop
##############################################################################
calibrate_i2c_port
while true; do
  raw=$(cat /sys/class/thermal/thermal_zone0/temp)
  c=$(echo "scale=1;$raw/1000" | bc)
  if [[ $temp_unit == C ]]; then t=$c;  unit="°C"
  else                           t=$(echo "scale=1;$c*9/5+32" | bc); unit="°F"; fi

  echo "Current Temperature = $t $unit"

  if fcomp "$t" -le "$tmini";      then fan=0
  elif fcomp "$t" -ge "$tmaxi";    then fan=100
  else
       range=$(echo "$tmaxi-$tmini" | bc)
       diff=$(echo "$t-$tmini" | bc)
       fan=$(echo "scale=0;($diff*100)/$range" | bc)
  fi

  action_linear "$fan" "$t" "$unit"
  sleep 30
done

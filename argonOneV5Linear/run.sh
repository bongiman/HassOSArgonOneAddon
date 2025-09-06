#!/usr/bin/with-contenv bashio
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

##############################################################################
# 1) Utilities
##############################################################################

# Ensure bc always sees a float
mkfloat() {
  local str="$1"
  [[ $str != *"."* ]] && str="${str}.0"
  echo "$str"
}

##############################################################################
# 2) Detect I²C bus and address
##############################################################################
calibrate_i2c_port() {
  if [[ -z $(ls /dev/i2c-* 2>/dev/null) ]]; then
    echo "Cannot find any /dev/i2c-* device – enable I²C first."
    sleep 5
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

  if [[ -z $detected_port ]]; then
    echo "ArgonOne device not found on any I²C port"
    sleep 5
    exit 1
  fi

  port=$detected_port
  echo "I²C Port $port"
}

##############################################################################
# 3) Pure-bash float comparison – fcomp "1.23" -le "4.56"
##############################################################################
fcomp() {
  local a="$1" op="$2" b="$3" sign_a=1 sign_b=1
  [[ $a == -* ]] && sign_a=-1 a=${a#-}
  [[ $b == -* ]] && sign_b=-1 b=${b#-}
  a=${a#+}; b=${b#+}
  local ai=${a%%.*} af=${a#*.}
  local bi=${b%%.*} bf=${b#*.}
  [[ $a == "$ai" ]] && af=""
  [[ $b == "$bi" ]] && bf=""
  while ((${#af} < ${#bf})); do af+=0; done
  while ((${#bf} < ${#af})); do bf+=0; done
  local A=$(( sign_a * 10#${ai}${af:-0} ))
  local B=$(( sign_b * 10#${bi}${bf:-0} ))
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

##############################################################################
# 4) Report fan speed to Home Assistant
##############################################################################
fan_speed_report() {
  local pct=$1 t=$2 unit=$3
  local body
  body=$(jq -nc --arg s "$pct" --arg t "$t" --arg u "$unit" '{
      state:$s,
      attributes:{
        unit_of_measurement:"%",
        icon:"mdi:fan",
        ("Temperature "+$u):$t,
        friendly_name:"Argon Fan Speed"
      }
  }')
  exec 3<>/dev/tcp/hassio/80 || { echo "HA API unreachable"; return; }
  printf 'POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n' >&3
  printf 'Host: hassio\r\n' >&3
  printf 'Authorization: Bearer %s\r\nConnection: close\r\n' "$SUPERVISOR_TOKEN" >&3
  printf 'Content-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3
  read -t 5 -r _ <&3 || echo "No reply from HA API"
  exec 3>&-
}

##############################################################################
# 5) Native PWM (Pi 5) fallback
##############################################################################
detect_pwm_sysfs() {
  for d in /sys/devices/platform/cooling_fan/hwmon/*; do
    [[ -e "$d/pwm1" ]] && { echo "$d"; return 0; }
  done
  return 1
}

write_pwm_native() {
  local pct=$1
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local val=$(( pct * 255 / 100 ))
  echo 1 > "$PWM_DIR/pwm1_enable" 2>/dev/null || return 1
  echo "$val" > "$PWM_DIR/pwm1" 2>/dev/null || return 1
  return 0
}

PWM_DIR="$(detect_pwm_sysfs || true)"
i2c_fail_count=0
I2C_FAIL_THRESHOLD=5

##############################################################################
# 6) Write fan PWM with robust fallback (V5 register + legacy + PWM)
##############################################################################
action_linear() {
  local pct=$1 temp=$2 unit=$3
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local hex; printf -v hex '0x%02x' "$pct"

  printf '%s: %s%s – Fan %s%% | hex:(%s)\n' "$(date '+%F_%T')" "$temp" "$unit" "$pct" "$hex"

  local ok=0
  if [[ -n "$port" ]]; then
    # Preferred Argon One V5 on Pi 5: register 0x80 + value, try 0x1a then 0x1b
    if i2cset -y "$port" 0x1a 0x80 "$hex" >/dev/null 2>&1; then
      ok=1
    elif i2cset -y "$port" 0x1b 0x80 "$hex" >/dev/null 2>&1; then
      ok=1
    # Legacy single-byte (older cases/firmware)
    elif i2cset -y "$port" 0x1a "$hex" >/dev/null 2>&1; then
      ok=1
    elif i2cset -y "$port" 0x1b "$hex" >/dev/null 2>&1; then
      ok=1
    fi
  fi

  if (( ok )); then
    i2c_fail_count=0
  else
    echo "I²C write failed on 0x1a/0x1b (0x80+val and single byte)"
    ((i2c_fail_count++))
    if (( i2c_fail_count >= I2C_FAIL_THRESHOLD )) && [[ -n "$PWM_DIR" ]]; then
      if write_pwm_native "$pct"; then
        echo "Switched to native PWM sysfs control at $PWM_DIR"
      else
        echo "Native PWM write failed at $PWM_DIR"
      fi
    fi
  fi

  [[ $create_entity == true ]] && fan_speed_report "$pct" "$temp" "$unit" &
  return 0
}

##############################################################################
# 7) Load options
##############################################################################
create_entity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo false)
[[ "$create_entity" != true ]] && create_entity=false
temp_unit=$(jq -r '."Temperature Unit"' /data/options.json 2>/dev/null || echo F)
[[ "$temp_unit" != C ]] && temp_unit=F
tmini=$(mkfloat "$(jq -r '."Minimum Temperature"' /data/options.json 2>/dev/null || echo 55)")
tmaxi=$(mkfloat "$(jq -r '."Maximum Temperature"' /data/options.json 2>/dev/null || echo 85)")
echo "Settings initialized. Argon One V5 Detected. Beginning monitor.."

##############################################################################
# 8) Main loop
##############################################################################
calibrate_i2c_port
while true; do
  raw=$(cat /sys/class/thermal/thermal_zone0/temp)
  c=$(echo "scale=1;$raw/1000" | bc)
  if [[ $temp_unit == C ]]; then t=$c; unit="°C"; else t=$(echo "scale=1;$c*9/5+32" | bc); unit="°F"; fi
  echo "Current Temperature = $t $unit"
  if fcomp "$t" -le "$tmini"; then
    fan=0
  elif fcomp "$t" -ge "$tmaxi"; then
    fan=100
  else
    range=$(echo "$tmaxi-$tmini" | bc)
    diff=$(echo "$t-$tmini" | bc)
    fan=$(echo "scale=0;($diff*100)/$range" | bc)
  fi
  if ! action_linear "$fan" "$t" "$unit"; then
    echo "Write failed, will retry next cycle"
  fi
  sleep 30
done

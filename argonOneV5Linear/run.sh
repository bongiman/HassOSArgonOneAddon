#!/usr/bin/with-contenv bashio
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

##############################################################################
# 1  Utility functions
##############################################################################

# Ensure a value is a float (adds “.0” if missing)
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
    local port_scan=${device##*/i2c-}
    echo "checking i2c port ${port_scan} at ${device}"
    local detection
    detection=$(i2cdetect -y "$port_scan")
    echo "$detection"
    if echo "$detection" | grep -q -E ' 1a | 1b '; then
      detected_port=$port_scan
      echo "found at $device"
      break
    fi
    echo "not found on $device"
  done

  if [[ -z $detected_port ]]; then
    echo "ArgonOne device not found on any I²C port"
    exit 1
  fi

  port=$detected_port
  echo "I²C Port $port"
}

##############################################################################
# 3  Pure-bash float comparison   – usage : fcomp \"1.23\" -le \"4.56\"
##############################################################################
fcomp() {
  local a="$1" op="$2" b="$3"

  # strip signs
  local sign_a=1 sign_b=1
  [[ $a == -* ]] && sign_a=-1 a=${a#-}
  [[ $b == -* ]] && sign_b=-1 b=${b#-}
  a=${a#+}; b=${b#+}

  # split integer / fraction
  local ai="${a%%.*}" af="${a#*.}"
  local bi="${b%%.*}" bf="${b#*.}"
  [[ $a == "$ai" ]] && af=""
  [[ $b == "$bi" ]] && bf=""

  # pad to same length
  while ((${#af} < ${#bf})); do af="${af}0"; done
  while ((${#bf} < ${#af})); do bf="${bf}0"; done

  local A="${ai}${af}" B="${bi}${bf}"
  [[ -z $A ]] && A=0
  [[ -z $B ]] && B=0
  (( A = sign_a * A,  B = sign_b * B ))

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
# 4  Push fan speed to Home Assistant
##############################################################################
fan_speed_report() {
  local fan_percent=$1 cpu_temp=$2 unit=$3
  local icon=mdi:fan body
  body=$(jq -nc --arg s "$fan_percent" --arg t "$cpu_temp" --arg u "$unit" \
               --arg icon "$icon" '{
      state: $s,
      attributes: {
        unit_of_measurement: "%",
        icon: $icon,
        ("Temperature "+$u): $t,
        friendly_name: "Argon Fan Speed"
      }}')

  exec 3<>/dev/tcp/hassio/80 || {
    echo "WARNING: cannot connect to Home Assistant."
    return 1
  }

  printf 'POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n' >&3
  printf 'Host: hassio\r\n' >&3                    # ← added Host header
  printf 'Connection: close\r\nAuthorization: Bearer %s\r\n' "$SUPERVISOR_TOKEN" >&3
  printf 'Content-Type: application/json\r\n' >&3
  printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3

  # simple read with 5 s timeout
  if read -t 5 -r _ <&3; then :; fi
  exec 3>&-
}

##############################################################################
# 5  Write fan PWM with fallback
##############################################################################
action_linear() {
  local fan_percent=$1 cpu_temp=$2 unit=$3
  (( fan_percent < 0 ))  && fan_percent=0
  (( fan_percent > 100 ))&& fan_percent=100
  local fan_hex
  printf -v fan_hex '0x%02x' "${fan_percent}"

  printf '%s: %s%s – Fan %s%% | hex:(%s)\n' \
         "$(date '+%Y-%m-%d_%H:%M:%S')" "$cpu_temp" "$unit" "$fan_percent" "$fan_hex"

  if ! i2cset -y "$port" 0x1a "$fan_hex" >/dev/null 2>&1; then
    i2cset -y "$port" 0x1b "$fan_hex" >/dev/null 2>&1 || {
      echo "I²C write failed on both 0x1a and 0x1b – Safe-Mode."
      return 1
    }
  fi

  [[ $create_entity == true ]] && fan_speed_report "$fan_percent" "$cpu_temp" "$unit" &
}

##############################################################################
# 6  Read add-on options
##############################################################################
tmini=$(jq -r '."Minimum Temperature"' /data/options.json 2>/dev/null || echo 55)
tmaxi=$(jq -r '."Maximum Temperature"' /data/options.json 2>/dev/null || echo 85)
create_entity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo false)
temp_unit=$(jq -r '."Temperature Unit"' /data/options.json 2>/dev/null || echo "F")

tmini=$(mkfloat "$tmini")
tmaxi=$(mkfloat "$tmaxi")
echo "Settings initialized. Argon One V5 Detected. Beginning monitor.."

##############################################################################
# 7  Start
##############################################################################
calibrate_i2c_port

while true; do
  cpu_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
  cpu_c=$(echo "scale=1; ${cpu_raw}/1000" | bc)

  if [[ $temp_unit == "C" ]]; then
    cpu_temp=$cpu_c; unit="°C"
  else
    cpu_temp=$(echo "scale=1; ${cpu_c}*9/5+32" | bc)
    unit="°F"
  fi

  echo "Current Temperature = ${cpu_temp} ${unit}"

  if fcomp "${cpu_temp}" -le "${tmini}"; then
    fan=0
  elif fcomp "${cpu_temp}" -ge "${tmaxi}"; then
    fan=100
  else
    range=$(echo "scale=2; ${tmaxi} - ${tmini}" | bc)
    diff=$(echo  "scale=2; ${cpu_temp} - ${tmini}" | bc)
    fan=$(echo  "scale=0;  ${diff} * 100 / ${range}" | bc)
  fi

  action_linear "$fan" "$cpu_temp" "$unit"
  sleep 30
done

#!/usr/bin/with-contenv bashio
# ArgonOne V5 Active Linear Cooling – Raspberry Pi 5

# ===============================
# 1) Utilities and options
# ===============================

log() { echo "$(date '+%F %T') $*"; }

mkfloat() {
  local s="$1"
  [[ $s != *"."* ]] && s="${s}.0"
  echo "$s"
}

# Optional hardening: allow overriding bus/backend via options.json
# Add to your add-on options.json if desired:
# "I2C Bus Override": 13
# "Backend": "Auto" | "I2C" | "PWM"

BUS_OVERRIDE=$(jq -r '."I2C Bus Override" // empty' /data/options.json 2>/dev/null || true)
BACKEND=$(jq -r '."Backend" // "Auto"' /data/options.json 2>/dev/null || echo Auto)

create_entity=$(jq -r '."Create Entity"' /data/options.json 2>/dev/null || echo false)
[[ "$create_entity" != true ]] && create_entity=false

temp_unit=$(jq -r '."Temperature Unit"' /data/options.json 2>/dev/null || echo F)
[[ "$temp_unit" != C ]] && temp_unit=F

tmini=$(mkfloat "$(jq -r '."Minimum Temperature"' /data/options.json 2>/dev/null || echo 55)")
tmaxi=$(mkfloat "$(jq -r '."Maximum Temperature"' /data/options.json 2>/dev/null || echo 85)")

log "Settings initialized. Argon One V5 Detected. Beginning monitor.."

# ===============================
# 2) Robust I²C port selection
# ===============================

# Accept bus only if 0x1a or 0x1b appear under read-probe and the grid is not “dense”
# Dense grid threshold guards against quick-probe artefacts that show many false hits
DENSE_THRESHOLD=20

select_i2c_port() {
  local candidate=""
  local buses=()

  if [[ -n "$BUS_OVERRIDE" ]]; then
    buses=("$BUS_OVERRIDE")
    log "I2C bus override requested: $BUS_OVERRIDE"
  else
    # Common Pi buses in priority order
    buses=(0 1 13)
  fi

  for b in "${buses[@]}"; do
    local dev="/dev/i2c-$b"
    [[ -e "$dev" ]] || { log "skip $dev (absent)"; continue; }
    log "read-probing $dev"
    # Read-probe avoids quick-probe false positives
    local scan
    scan=$(i2cdetect -y -r "$b" 2>/dev/null || true)
    echo "$scan"
    local hits
    hits=$(echo "$scan" | grep -oE ' [0-9a-f]{2} ' | wc -l | tr -d ' ')
    if (( hits > DENSE_THRESHOLD )); then
      log "grid too dense on bus $b (${hits} hits) – likely noisy, skipping"
      continue
    fi
    if echo "$scan" | grep -q -E ' 1a | 1b '; then
      candidate="$b"
      log "selected $dev by read-probe"
      break
    else
      log "0x1a/0x1b not found on $dev"
    fi
  done

  echo "$candidate"
}

# ===============================
# 3) Float comparison: fcomp "1.23" -le "4.56"
# ===============================

fcomp() {
  local a="$1" op="$2" b="$3" sa=1 sb=1
  [[ $a == -* ]] && sa=-1 a=${a#-}
  [[ $b == -* ]] && sb=-1 b=${b#-}
  a=${a#+}; b=${b#+}
  local ai=${a%%.*} af=${a#*.} bi=${b%%.*} bf=${b#*.}
  [[ $a == "$ai" ]] && af=""
  [[ $b == "$bi" ]] && bf=""
  while ((${#af} < ${#bf})); do af+=0; done
  while ((${#bf} < ${#af})); do bf+=0; done
  local A=$(( sa * 10#${ai}${af:-0} ))
  local B=$(( sb * 10#${bi}${bf:-0} ))
  case "$op" in
    -lt) (( A <  B ));;
    -le) (( A <= B ));;
    -gt) (( A >  B ));;
    -ge) (( A >= B ));;
    -eq) (( A == B ));;
    -ne) (( A != B ));;
  esac
}

# ===============================
# 4) HA reporting
# ===============================

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
  exec 3<>/dev/tcp/hassio/80 || { log "HA API unreachable"; return; }
  printf 'POST /homeassistant/api/states/sensor.argon_one_addon_fan_speed HTTP/1.1\r\n' >&3
  printf 'Host: hassio\r\n' >&3
  printf 'Authorization: Bearer %s\r\nConnection: close\r\n' "$SUPERVISOR_TOKEN" >&3
  printf 'Content-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3
  read -t 5 -r _ <&3 || log "No reply from HA API"
  exec 3>&-
}

# ===============================
# 5) PWM backend (Pi 5)
# ===============================

detect_pwm_sysfs() {
  # Try common Pi 5 cooling_fan path first
  for d in /sys/devices/platform/cooling_fan/hwmon/*; do
    [[ -e "$d/pwm1" ]] && { echo "$d"; return 0; }
  done
  # Fallback: search all hwmon nodes for pwm1
  for d in /sys/class/hwmon/hwmon*; do
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

# ===============================
# 6) Robust writer: i2ctransfer → i2cset → PWM
# ===============================

CURRENT_BACKEND="Auto"  # Auto, I2C, PWM (runtime)
port=""

try_i2c_write() {
  local pct=$1
  local ok=0
  # i2ctransfer: write two bytes (register 0x80 + PWM value)
  if i2ctransfer -y "$port" w2@0x1a 0x80 "$pct" >/dev/null 2>&1; then
    ok=1
  elif i2ctransfer -y "$port" w2@0x1b 0x80 "$pct" >/dev/null 2>&1; then
    ok=1
  # i2cset with register, then legacy single-byte
  elif i2cset -y "$port" 0x1a 0x80 0x$(printf '%02x' "$pct") >/dev/null 2>&1; then
    ok=1
  elif i2cset -y "$port" 0x1b 0x80 0x$(printf '%02x' "$pct") >/dev/null 2>&1; then
    ok=1
  elif i2cset -y "$port" 0x1a 0x$(printf '%02x' "$pct") >/dev/null 2>&1; then
    ok=1
  elif i2cset -y "$port" 0x1b 0x$(printf '%02x' "$pct") >/dev/null 2>&1; then
    ok=1
  fi
  return $ok
}

action_linear() {
  local pct=$1 temp=$2 unit=$3
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  log "Temp $temp$unit – Fan ${pct}% (backend=$CURRENT_BACKEND)"

  if [[ "$CURRENT_BACKEND" == "I2C" || "$CURRENT_BACKEND" == "Auto" ]] && [[ -n "$port" ]]; then
    if try_i2c_write "$pct"; then
      i2c_fail_count=0
    else
      log "I²C write failed on 0x1a/0x1b (transfer + set paths)"
      ((i2c_fail_count++))
      if (( i2c_fail_count >= I2C_FAIL_THRESHOLD )) && [[ "$CURRENT_BACKEND" == "Auto" ]] && [[ -n "$PWM_DIR" ]]; then
        CURRENT_BACKEND="PWM"
        log "Switching backend to PWM at $PWM_DIR"
      fi
    fi
  fi

  if [[ "$CURRENT_BACKEND" == "PWM" ]]; then
    if ! write_pwm_native "$pct"; then
      log "PWM write failed at $PWM_DIR"
    fi
  fi

  [[ $create_entity == true ]] && fan_speed_report "$pct" "$temp" "$unit" &
}

# ===============================
# 7) Main
# ===============================

# Decide backend up-front
if [[ "$BACKEND" == "I2C" ]]; then
  CURRENT_BACKEND="I2C"
elif [[ "$BACKEND" == "PWM" ]]; then
  CURRENT_BACKEND="PWM"
else
  CURRENT_BACKEND="Auto"
fi

# Select I²C port unless backend is forced to PWM
if [[ "$CURRENT_BACKEND" != "PWM" ]]; then
  sel=$(select_i2c_port)
  if [[ -n "$sel" ]]; then
    port="$sel"
    [[ "$CURRENT_BACKEND" == "Auto" ]] && CURRENT_BACKEND="I2C"
  else
    log "No I²C Argon MCU found by read-probe"
    [[ "$CURRENT_BACKEND" == "Auto" ]] && CURRENT_BACKEND="PWM"
  fi
fi

while true; do
  raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  c=$(echo "scale=1;$raw/1000" | bc)
  if [[ $temp_unit == C ]]; then
    t=$c; unit="°C"
  else
    t=$(echo "scale=1;$c*9/5+32" | bc); unit="°F"
  fi

  log "Current Temperature = $t $unit"

  if fcomp "$t" -le "$tmini"; then
    fan=0
  elif fcomp "$t" -ge "$tmaxi"; then
    fan=100
  else
    range=$(echo "$tmaxi - $tmini" | bc)
    diff=$(echo "$t - $tmini" | bc)
    fan=$(echo "scale=0; ($diff * 100) / $range" | bc)
  fi

  action_linear "$fan" "$t" "$unit"
  sleep 30
done
